// Host log collection, the fleet workbook and the alerts.
//
// deploy/Enable-HostMonitoring.ps1 installs the Azure Monitor agent and associates these data
// collection rules with the hosts. Bicep cannot do it: adding a VM extension fails on a
// deallocated VM, and scaling powers hosts off.

@description('Location of the data collection rules, the workbook and the log alerts.')
param location string = resourceGroup().location
param tags object = {}

@description('Prefix of the resource names, <appName>-<environmentName>.')
param namePrefix string

@description('Log Analytics workspace that Application Insights writes to. The host logs go there too.')
param logAnalyticsWorkspaceName string

@description('Name of the broker API web app, which is the cloud role name of its telemetry.')
param apiAppName string

@description('Storage account of the NFS share the deployment provisions, or empty when it provisions none.')
param nfsStorageAccountName string = ''

@description('Email addresses that receive the alerts, separated by commas or semicolons. Leave empty to deploy the alerts without notifications.')
param alertEmailAddresses string = ''

@description('Refused checkouts (HTTP 409) in 15 minutes that raise an alert.')
@minValue(1)
param alertCheckoutRefusalThreshold int = 1

@description('API responses with a 5xx status in 15 minutes that raise an alert.')
@minValue(1)
param alertApiErrorThreshold int = 5

@description('Average end-to-end latency of the NFS share over 15 minutes, in milliseconds, that raises an alert.')
@minValue(1)
param alertNfsLatencyThresholdMs int = 50

var hostLogTableName = 'LinuxBrokerHost_CL'
var hostLogStreamName = 'Custom-${hostLogTableName}'

// Each broker log line starts with a YYYY-MM-DD HH:MM:SS timestamp, which starts a record. xrdp
// starts its lines with a timestamp in brackets instead, [YYYYMMDD-HH:MM:SS] in 0.9 and
// [YYYY-MM-DDTHH:MM:SS.mmm+zzzz] in 0.10, and a file in which no line starts with the format is
// split into records at each line end.
var linuxHostLogFiles = [
  '/var/log/release-session.log'
  '/var/log/release-session-watcher.log'
  '/var/log/linuxbroker-host-settings.log'
  '/var/log/createuser.log'
  '/var/log/linuxbroker-session-control.log'
  '/var/log/linuxbroker-patch.log'
  '/var/log/xrdp.log'
  '/var/log/xrdp-sesman.log'
]

var alertEmailList = filter(map(split(replace(alertEmailAddresses, ';', ','), ','), address => trim(address)), address => !empty(address))
var alertActionGroupIds = empty(alertEmailList) ? [] : [alertActionGroup.id]
var monitorNfsShare = !empty(nfsStorageAccountName)
var nfsFileServiceId = resourceId('Microsoft.Storage/storageAccounts/fileServices', monitorNfsShare ? nfsStorageAccountName : 'none', 'default')

// The queries are built from single-line strings so that main.json is the same whichever line
// endings the checkout has. Workbook queries bin by the time range's grain, but never below the
// five minutes between fleet snapshots.
var fleetSnapshots = [
  'AppTraces'
  '| where AppRoleName == "${apiAppName}" and Message == "fleet snapshot"'
]
var apiRequests = [
  'AppRequests'
  '| where AppRoleName == "${apiAppName}"'
]
// The request's path, or the route in the span name when the URL is missing.
var requestPath = '| extend Path = coalesce(tostring(parse_url(Url).Path), tostring(split(Name, " ")[-1]))'
var workbookBin = 'bin(TimeGenerated, max_of(5m, {TimeRange:grain}))'
var hostLogLevel = '| extend Level = case(RawData has_cs "ERROR", "Error", RawData has_cs "WARNING" or RawData has_cs "WARN", "Warning", RawData has_any ("failed", "cannot", "unable") or RawData has "could not", "Error", "")'

var latestSnapshotQuery = join(concat(fleetSnapshots, [
  '| top 1 by TimeGenerated desc'
  '| project TimeGenerated, Ready = toint(Properties.ReadyHosts), InUse = toint(Properties.InUse), Waiting = toint(Properties.Waiting), Booting = toint(Properties.Booting), PoweredOn = toint(Properties.PoweredOn), Total = toint(Properties.TotalHosts), MinVMs = toint(Properties.EffectiveMinVMs), MaxVMs = toint(Properties.MaxVMs), StaleHeartbeats = toint(Properties.StaleHeartbeats), NfsUnreachable = toint(Properties.NfsUnreachable), XrdpInactive = toint(Properties.XrdpInactive), Draining = toint(Properties.Draining), Maintenance = toint(Properties.Maintenance), StartOnDemand = iff(toint(Properties.StartOnDemandEnabled) == 1, "On", "Off")'
]), '\n')

var fleetTrendQuery = join(concat(fleetSnapshots, [
  '| summarize Ready = min(toint(Properties.ReadyHosts)), InUse = max(toint(Properties.InUse)), Waiting = max(toint(Properties.Waiting)), Booting = max(toint(Properties.Booting)), PoweredOn = max(toint(Properties.PoweredOn)) by ${workbookBin}'
  '| order by TimeGenerated asc'
]), '\n')

var checkoutOutcomeQuery = join(concat(apiRequests, [
  requestPath
  '| where Path == "/api/vms/checkout"'
  '| extend Outcome = case(ResultCode == "200", "Assigned (200)", ResultCode == "202", "Starting a host (202)", ResultCode == "409", "Refused (409)", toint(ResultCode) >= 500, "Failed (5xx)", strcat("Other (", ResultCode, ")"))'
  '| summarize Checkouts = count() by Outcome, ${workbookBin}'
  '| order by TimeGenerated asc'
]), '\n')

var checkoutLatencyQuery = join(concat(apiRequests, [
  '| where ResultCode == "200"'
  requestPath
  '| where Path == "/api/vms/checkout"'
  '| summarize P50 = percentile(DurationMs, 50), P95 = percentile(DurationMs, 95) by ${workbookBin}'
  '| order by TimeGenerated asc'
]), '\n')

var releaseQuery = join(concat(apiRequests, [
  requestPath
  '| extend Action = case(Path matches regex @"^/api/vms/[^/]+/release$", "Release", Path matches regex @"^/api/vms/[^/]+/return$", "Return", "")'
  '| where isnotempty(Action)'
  '| extend Series = strcat(Action, iff(toint(ResultCode) < 400, " succeeded", strcat(" failed (", ResultCode, ")")))'
  '| summarize Requests = count() by Series, ${workbookBin}'
  '| order by TimeGenerated asc'
]), '\n')

var startOnDemandQuery = join([
  'union'
  '    (AppTraces'
  '    | where AppRoleName == "${apiAppName}" and tostring(Properties.audit_action) == "vm.start_on_demand"'
  '    | extend Series = iff(tostring(Properties.audit_outcome) == "success", "Hosts started", "Starts that failed")),'
  '    (AppRequests'
  '    | where AppRoleName == "${apiAppName}" and ResultCode == "202"'
  '    ${requestPath}'
  '    | where Path == "/api/vms/checkout"'
  '    | extend Series = "Checkouts told to wait (202)")'
  '| summarize Events = count() by Series, ${workbookBin}'
  '| order by TimeGenerated asc'
], '\n')

var settingsFailureQuery = join([
  'LinuxBrokerHost_CL'
  '| where FilePath endswith "linuxbroker-host-settings.log"'
  '| where RawData has_cs "ERROR" or RawData has_cs "WARNING"'
  '| project TimeGenerated, Computer, Level = iff(RawData has_cs "ERROR", "Error", "Warning"), Message = RawData'
  '| order by TimeGenerated desc'
  '| take 200'
], '\n')

var hostErrorQuery = join([
  'union isfuzzy=true'
  '    (LinuxBrokerHost_CL'
  '    ${hostLogLevel}'
  '    | where isnotempty(Level)'
  '    | extend Source = extract(@"([^/]+)$", 1, FilePath), Message = RawData),'
  '    (Syslog'
  '    | where SeverityLevel in ("emerg", "alert", "crit", "err")'
  '    | extend Level = "Error", Source = iff(isempty(ProcessName), strcat("syslog ", Facility), strcat("syslog ", Facility, " ", ProcessName)), Message = SyslogMessage)'
  '| summarize Events = count(), arg_max(TimeGenerated, Message) by Computer, Source, Level'
  '| project Computer, Source, Level, Events, LastSeen = TimeGenerated, LatestMessage = Message'
  '| order by Events desc'
], '\n')

var nfsFailureQuery = join([
  'union isfuzzy=true'
  '    (LinuxBrokerHost_CL'
  '    | where FilePath endswith "createuser.log" and RawData has "Failed to mount NFS share"'
  '    | extend Source = "create-user.sh"),'
  '    (LinuxBrokerHost_CL'
  '    | where FilePath endswith "linuxbroker-session-control.log" and RawData has "Could not mount the profile share"'
  '    | extend Source = "session-control.sh"),'
  '    (Syslog'
  '    | where Facility == "kern" and SyslogMessage has "nfs" and (SyslogMessage has "not responding" or SyslogMessage has "timed out")'
  '    | extend Source = "kernel", RawData = SyslogMessage)'
  '| project TimeGenerated, Computer, Source, Message = RawData'
  '| order by TimeGenerated desc'
  '| take 500'
], '\n')

var avdEventQuery = join([
  'Event'
  '| where Source == "LinuxBrokerScript" or EventLog == "Microsoft-Windows-TerminalServices-RDPClient/Operational"'
  '| where EventLevelName in ("Critical", "Error", "Warning")'
  '| summarize Events = count(), arg_max(TimeGenerated, RenderedDescription) by Computer, Source, Level = EventLevelName'
  '| project Computer, Source, Level, Events, LastSeen = TimeGenerated, LatestMessage = RenderedDescription'
  '| order by Events desc'
], '\n')

// Each fleet alert needs every snapshot in its 15-minute window to show the problem, so a host
// that is briefly busy or booting does not raise one.
var noReadyHostsAlertQuery = join(concat(fleetSnapshots, [
  '| extend Ready = toint(Properties.ReadyHosts), MinVMs = toint(Properties.EffectiveMinVMs), Waiting = toint(Properties.Waiting)'
  '| summarize Snapshots = count(), Short = countif(Ready == 0 and (MinVMs > 0 or Waiting > 0)), MostWaiting = max(Waiting)'
  '| where Snapshots > 0 and Short == Snapshots'
]), '\n')

var unhealthyHostsAlertQuery = join(concat(fleetSnapshots, [
  '| extend Stale = toint(Properties.StaleHeartbeats), Nfs = toint(Properties.NfsUnreachable), Xrdp = toint(Properties.XrdpInactive)'
  '| summarize Snapshots = count(), Lowest = min(Stale + Nfs + Xrdp), StaleHeartbeats = max(Stale), NfsUnreachable = max(Nfs), XrdpInactive = max(Xrdp)'
  '| where Snapshots > 0 and Lowest > 0'
]), '\n')

var refusedCheckoutAlertQuery = join(concat(apiRequests, [
  '| where ResultCode == "409"'
  requestPath
  '| where Path == "/api/vms/checkout"'
]), '\n')

var apiErrorAlertQuery = join(concat(apiRequests, [
  '| where toint(ResultCode) >= 500'
]), '\n')

var logAlerts = [
  {
    name: 'no-ready-hosts'
    displayName: 'Linux Broker: no ready hosts (${namePrefix})'
    description: 'For 15 minutes every fleet snapshot showed no ready Linux host while the scaling minimum is above 0 or users are waiting. Check the Linux hosts and the scaling settings.'
    severity: 1
    query: noReadyHostsAlertQuery
    operator: 'GreaterThan'
    threshold: 0
  }
  {
    name: 'fleet-snapshot-missing'
    displayName: 'Linux Broker: no fleet snapshot (${namePrefix})'
    description: 'The scaling run has logged no fleet snapshot for 15 minutes. The task function, the API or the database may be down, or SQL script 157 is not applied yet.'
    severity: 2
    query: join(fleetSnapshots, '\n')
    operator: 'LessThan'
    threshold: 1
  }
  {
    name: 'checkouts-refused'
    displayName: 'Linux Broker: checkouts refused (${namePrefix})'
    description: 'The broker refused checkouts (HTTP 409) in the last 15 minutes, so users could not get a Linux desktop.'
    severity: 2
    query: refusedCheckoutAlertQuery
    operator: 'GreaterThanOrEqual'
    threshold: alertCheckoutRefusalThreshold
  }
  {
    name: 'unhealthy-hosts'
    displayName: 'Linux Broker: unhealthy hosts (${namePrefix})'
    description: 'For 15 minutes every fleet snapshot showed a Linux host with a stale heartbeat, an unreachable home share or no xrdp service. The workbook lists the hosts\' errors.'
    severity: 2
    query: unhealthyHostsAlertQuery
    operator: 'GreaterThan'
    threshold: 0
  }
  {
    name: 'api-errors'
    displayName: 'Linux Broker: API errors (${namePrefix})'
    description: 'The broker API answered requests with a 5xx status in the last 15 minutes.'
    severity: 2
    query: apiErrorAlertQuery
    operator: 'GreaterThanOrEqual'
    threshold: alertApiErrorThreshold
  }
]

var nfsThrottlingResponseTypes = [
  'SuccessWithThrottling'
  'SuccessWithShareIopsThrottling'
  'SuccessWithShareEgressThrottling'
  'SuccessWithShareIngressThrottling'
  'SuccessWithMetadataThrottling'
  'ClientThrottlingError'
  'ClientShareIopsThrottlingError'
  'ClientShareEgressThrottlingError'
  'ClientShareIngressThrottlingError'
]

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' existing = {
  name: logAnalyticsWorkspaceName
}

resource hostLogTable 'Microsoft.OperationalInsights/workspaces/tables@2023-09-01' = {
  parent: workspace
  name: hostLogTableName
  properties: {
    plan: 'Analytics'
    schema: {
      name: hostLogTableName
      columns: [
        {
          name: 'TimeGenerated'
          type: 'dateTime'
        }
        {
          name: 'RawData'
          type: 'string'
        }
        {
          name: 'FilePath'
          type: 'string'
        }
        {
          name: 'Computer'
          type: 'string'
        }
      ]
    }
  }
}

resource linuxHostRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: take('dcr-${namePrefix}-linux', 64)
  location: location
  tags: tags
  kind: 'Linux'
  properties: {
    description: 'Linux Broker logs, xrdp logs and syslog from the Linux hosts.'
    streamDeclarations: {
      '${hostLogStreamName}': {
        columns: [
          {
            name: 'TimeGenerated'
            type: 'datetime'
          }
          {
            name: 'RawData'
            type: 'string'
          }
          {
            name: 'FilePath'
            type: 'string'
          }
          {
            name: 'Computer'
            type: 'string'
          }
        ]
      }
    }
    dataSources: {
      logFiles: [
        {
          name: 'linuxBrokerLogs'
          streams: [
            hostLogStreamName
          ]
          filePatterns: linuxHostLogFiles
          format: 'text'
          settings: {
            text: {
              recordStartTimestampFormat: 'YYYY-MM-DD HH:MM:SS'
            }
          }
        }
      ]
      syslog: [
        {
          name: 'authentication'
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: [
            'auth'
            'authpriv'
          ]
          logLevels: [
            'Info'
            'Notice'
            'Warning'
            'Error'
            'Critical'
            'Alert'
            'Emergency'
          ]
        }
        {
          // The kernel reports an NFS server that stops answering at notice level.
          name: 'kernelAndUser'
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: [
            'kern'
            'user'
          ]
          logLevels: [
            'Notice'
            'Warning'
            'Error'
            'Critical'
            'Alert'
            'Emergency'
          ]
        }
        {
          name: 'otherFacilities'
          streams: [
            'Microsoft-Syslog'
          ]
          facilityNames: [
            'cron'
            'daemon'
            'ftp'
            'local0'
            'local1'
            'local2'
            'local3'
            'local4'
            'local5'
            'local6'
            'local7'
            'lpr'
            'mail'
            'news'
            'syslog'
            'uucp'
          ]
          logLevels: [
            'Warning'
            'Error'
            'Critical'
            'Alert'
            'Emergency'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'workspace'
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          hostLogStreamName
        ]
        destinations: [
          'workspace'
        ]
        transformKql: 'source'
        outputStream: hostLogStreamName
      }
      {
        streams: [
          'Microsoft-Syslog'
        ]
        destinations: [
          'workspace'
        ]
      }
    ]
  }
  dependsOn: [
    hostLogTable
  ]
}

resource avdHostRule 'Microsoft.Insights/dataCollectionRules@2023-03-11' = {
  name: take('dcr-${namePrefix}-avd', 64)
  location: location
  tags: tags
  kind: 'Windows'
  properties: {
    description: 'Connect-LinuxBroker.ps1 events and Remote Desktop client problems from the AVD session hosts.'
    dataSources: {
      windowsEventLogs: [
        {
          name: 'linuxBrokerEvents'
          streams: [
            'Microsoft-Event'
          ]
          xPathQueries: [
            'Application!*[System[Provider[@Name=\'LinuxBrokerScript\']]]'
            'Microsoft-Windows-TerminalServices-RDPClient/Operational!*[System[(Level=1 or Level=2 or Level=3)]]'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: 'workspace'
          workspaceResourceId: workspace.id
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Event'
        ]
        destinations: [
          'workspace'
        ]
      }
    ]
  }
}

var workbookBaseQuery = {
  version: 'KqlItem/1.0'
  size: 0
  timeContextFromParameter: 'TimeRange'
  queryType: 0
  resourceType: 'microsoft.operationalinsights/workspaces'
  crossComponentResources: [
    workspace.id
  ]
}

var workbookContent = {
  version: 'Notebook/1.0'
  items: [
    {
      type: 1
      name: 'introduction'
      content: {
        json: '## Linux Broker fleet\nThe scaling run logs a fleet snapshot every five minutes. Host logs arrive once deploy/Enable-HostMonitoring.ps1 has installed the Azure Monitor agent on the hosts.'
      }
    }
    {
      type: 9
      name: 'parameters'
      content: {
        version: 'KqlParameterItem/1.0'
        style: 'pills'
        queryType: 0
        resourceType: 'microsoft.operationalinsights/workspaces'
        parameters: [
          {
            id: '5d0c8f3e-2a41-4b8e-9f6d-1c7a3b2e4f10'
            version: 'KqlParameterItem/1.0'
            name: 'TimeRange'
            label: 'Time range'
            type: 4
            isRequired: true
            value: {
              durationMs: 86400000
            }
            typeSettings: {
              allowCustom: true
              selectableValues: [
                {
                  durationMs: 3600000
                }
                {
                  durationMs: 14400000
                }
                {
                  durationMs: 43200000
                }
                {
                  durationMs: 86400000
                }
                {
                  durationMs: 259200000
                }
                {
                  durationMs: 604800000
                }
                {
                  durationMs: 2592000000
                }
              ]
            }
          }
        ]
      }
    }
    {
      type: 3
      name: 'latest-snapshot'
      content: union(workbookBaseQuery, {
        title: 'Latest fleet snapshot'
        query: latestSnapshotQuery
        visualization: 'table'
        noDataMessage: 'No fleet snapshot in this time range. The API logs one every five minutes once SQL script 157 is applied.'
      })
    }
    {
      type: 3
      name: 'fleet-trend'
      customWidth: '50'
      content: union(workbookBaseQuery, {
        title: 'Hosts over time (fewest ready, most in use, waiting, booting and powered on)'
        query: fleetTrendQuery
        visualization: 'timechart'
      })
    }
    {
      type: 3
      name: 'checkout-outcomes'
      customWidth: '50'
      content: union(workbookBaseQuery, {
        title: 'Checkouts by outcome'
        query: checkoutOutcomeQuery
        visualization: 'timechart'
      })
    }
    {
      type: 3
      name: 'checkout-latency'
      customWidth: '50'
      content: union(workbookBaseQuery, {
        title: 'Checkout time in milliseconds (50th and 95th percentile)'
        query: checkoutLatencyQuery
        visualization: 'timechart'
      })
    }
    {
      type: 3
      name: 'releases'
      customWidth: '50'
      content: union(workbookBaseQuery, {
        title: 'Releases and returns'
        query: releaseQuery
        visualization: 'timechart'
      })
    }
    {
      type: 3
      name: 'start-on-demand'
      customWidth: '50'
      content: union(workbookBaseQuery, {
        title: 'Hosts started on demand'
        query: startOnDemandQuery
        visualization: 'timechart'
      })
    }
    {
      type: 3
      name: 'settings-failures'
      customWidth: '50'
      content: union(workbookBaseQuery, {
        title: 'Host settings that could not be applied'
        query: settingsFailureQuery
        visualization: 'table'
        noDataMessage: 'No host setting errors or warnings in this time range.'
      })
    }
    {
      type: 3
      name: 'host-errors'
      content: union(workbookBaseQuery, {
        title: 'Errors and warnings by Linux host'
        query: hostErrorQuery
        visualization: 'table'
        noDataMessage: 'No host errors in this time range, or the Azure Monitor agent is not installed yet.'
      })
    }
    {
      type: 3
      name: 'nfs-failures'
      customWidth: '50'
      content: union(workbookBaseQuery, {
        title: 'NFS home share failures'
        query: nfsFailureQuery
        visualization: 'table'
        noDataMessage: 'No NFS mount failures in this time range.'
      })
    }
    {
      type: 3
      name: 'avd-events'
      customWidth: '50'
      content: union(workbookBaseQuery, {
        title: 'Errors and warnings by AVD session host'
        query: avdEventQuery
        visualization: 'table'
        noDataMessage: 'No AVD session host errors in this time range, or the Azure Monitor agent is not installed yet.'
      })
    }
  ]
  fallbackResourceIds: [
    workspace.id
  ]
  '$schema': 'https://github.com/Microsoft/Application-Insights-Workbooks/blob/master/schema/workbook.json'
}

resource fleetWorkbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, namePrefix, 'linuxbroker-fleet-workbook')
  location: location
  tags: tags
  kind: 'shared'
  properties: {
    displayName: 'Linux Broker fleet (${namePrefix})'
    category: 'workbook'
    sourceId: toLower(workspace.id)
    version: 'Notebook/1.0'
    serializedData: string(workbookContent)
  }
}

resource alertActionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = if (!empty(alertEmailList)) {
  name: 'ag-${namePrefix}'
  location: 'Global'
  tags: tags
  properties: {
    groupShortName: 'LinuxBroker'
    enabled: true
    emailReceivers: [
      for (address, i) in alertEmailList: {
        name: 'email-${i + 1}'
        emailAddress: address
        useCommonAlertSchema: true
      }
    ]
  }
}

resource logAlertRules 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = [
  for alert in logAlerts: {
    name: 'alert-${namePrefix}-${alert.name}'
    location: location
    tags: tags
    kind: 'LogAlert'
    properties: {
      displayName: alert.displayName
      description: alert.description
      severity: alert.severity
      enabled: true
      evaluationFrequency: 'PT5M'
      windowSize: 'PT15M'
      scopes: [
        workspace.id
      ]
      // Application Insights creates its tables only when its first telemetry arrives.
      skipQueryValidation: true
      autoMitigate: true
      criteria: {
        allOf: [
          {
            query: alert.query
            timeAggregation: 'Count'
            operator: alert.operator
            threshold: alert.threshold
            failingPeriods: {
              numberOfEvaluationPeriods: 1
              minFailingPeriodsToAlert: 1
            }
          }
        ]
      }
      actions: {
        actionGroups: alertActionGroupIds
      }
    }
  }
]

resource nfsThrottlingAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (monitorNfsShare) {
  name: 'alert-${namePrefix}-nfs-throttling'
  location: 'global'
  tags: tags
  properties: {
    description: 'Azure Files throttled requests to the NFS home share in the last 15 minutes. Users may see slow sign-ins and applications; see the sizing guide in DEPLOYMENT.md.'
    severity: 2
    enabled: true
    scopes: [
      nfsFileServiceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'ThrottledTransactions'
          metricNamespace: 'Microsoft.Storage/storageAccounts/fileServices'
          metricName: 'Transactions'
          dimensions: [
            {
              name: 'ResponseType'
              operator: 'Include'
              values: nfsThrottlingResponseTypes
            }
          ]
          operator: 'GreaterThan'
          threshold: 0
          timeAggregation: 'Total'
        }
      ]
    }
    actions: [
      for actionGroupId in alertActionGroupIds: {
        actionGroupId: actionGroupId
      }
    ]
  }
}

resource nfsLatencyAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = if (monitorNfsShare) {
  name: 'alert-${namePrefix}-nfs-latency'
  location: 'global'
  tags: tags
  properties: {
    description: 'The NFS home share answered slowly on average over the last 15 minutes.'
    severity: 3
    enabled: true
    scopes: [
      nfsFileServiceId
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    autoMitigate: true
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'EndToEndLatency'
          metricNamespace: 'Microsoft.Storage/storageAccounts/fileServices'
          metricName: 'SuccessE2ELatency'
          operator: 'GreaterThan'
          threshold: alertNfsLatencyThresholdMs
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      for actionGroupId in alertActionGroupIds: {
        actionGroupId: actionGroupId
      }
    ]
  }
}

output linuxHostDataCollectionRuleId string = linuxHostRule.id
output avdHostDataCollectionRuleId string = avdHostRule.id
