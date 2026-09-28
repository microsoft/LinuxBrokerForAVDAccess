// Power-management autoscale for the pooled host pool. Azure Virtual Desktop starts and
// deallocates the session hosts on this schedule, which needs the Azure Virtual Desktop service
// principal to hold Desktop Virtualization Power On Off Contributor on the subscription
// (assigned from main.bicep).

param location string
param tags object = {}

@minLength(3)
@maxLength(64)
param name string
param friendlyName string = name

@description('Name of the pooled host pool the plan scales, in the same resource group.')
param hostPoolName string

@description('Scales the host pool. False keeps the plan but assigns it to no host pool, so the session hosts are left as they are and another plan can be assigned instead.')
param enabled bool = true

@description('Windows time zone ID the schedule times are in, for example UTC or Eastern Standard Time.')
param timeZone string = 'UTC'

@description('Session hosts that carry this tag are never started, stopped or taken out of drain mode by autoscale.')
param exclusionTag string = 'excludeFromScaling'

@description('Weekday start of ramp-up, as HH:mm in timeZone. The weekend uses the same times.')
param rampUpStartTime string = '07:00'

@description('Start of peak hours, as HH:mm. Must come after ramp-up.')
param peakStartTime string = '09:00'

@description('Start of ramp-down, as HH:mm. Must come after peak.')
param rampDownStartTime string = '18:00'

@description('Start of off-peak hours, as HH:mm. Must come after ramp-down.')
param offPeakStartTime string = '20:00'

@description('Share of the session hosts kept on from ramp-up until ramp-down on weekdays, rounded up to whole hosts.')
@minValue(0)
@maxValue(100)
param rampUpMinimumHostsPct int = 20

@description('Share of the running hosts\' sessions that makes autoscale start another host during ramp-up and peak hours.')
@minValue(1)
@maxValue(100)
param rampUpCapacityThresholdPct int = 60

@description('Share of the session hosts kept on from ramp-down until the next ramp-up on weekdays, rounded up to whole hosts.')
@minValue(0)
@maxValue(100)
param rampDownMinimumHostsPct int = 10

@description('Share of the running hosts\' sessions that makes autoscale start another host during ramp-down and off-peak hours.')
@minValue(1)
@maxValue(100)
param rampDownCapacityThresholdPct int = 90

@description('Share of the session hosts kept on through Saturday and Sunday. 0 lets every host turn off, and Start VM on Connect starts one for the first user.')
@minValue(0)
@maxValue(100)
param weekendMinimumHostsPct int = 0

var rampUpTime = split(rampUpStartTime, ':')
var peakTime = split(peakStartTime, ':')
var rampDownTime = split(rampDownStartTime, ':')
var offPeakTime = split(offPeakStartTime, ':')

// Breadth-first while hosts are coming on spreads users out; depth-first once demand falls packs
// them onto fewer hosts, so the rest can stop. Users are never signed out: a host stops only once
// it has no session at all, disconnected ones included.
var sharedScheduleSettings = {
  rampUpStartTime: {
    hour: int(rampUpTime[0])
    minute: int(rampUpTime[1])
  }
  rampUpLoadBalancingAlgorithm: 'BreadthFirst'
  rampUpCapacityThresholdPct: rampUpCapacityThresholdPct
  peakStartTime: {
    hour: int(peakTime[0])
    minute: int(peakTime[1])
  }
  peakLoadBalancingAlgorithm: 'BreadthFirst'
  rampDownStartTime: {
    hour: int(rampDownTime[0])
    minute: int(rampDownTime[1])
  }
  rampDownLoadBalancingAlgorithm: 'DepthFirst'
  rampDownCapacityThresholdPct: rampDownCapacityThresholdPct
  rampDownForceLogoffUsers: false
  rampDownStopHostsWhen: 'ZeroSessions'
  rampDownWaitTimeMinutes: 30
  rampDownNotificationMessage: 'This session host is about to shut down. Save your work and sign out.'
  offPeakStartTime: {
    hour: int(offPeakTime[0])
    minute: int(offPeakTime[1])
  }
  offPeakLoadBalancingAlgorithm: 'DepthFirst'
}

resource hostPool 'Microsoft.DesktopVirtualization/hostPools@2024-04-03' existing = {
  name: hostPoolName
}

// Azure checks that the Azure Virtual Desktop service principal can reach the host pool before it
// assigns the plan to it, and answers 400 BadRequest when the role is missing.
resource scalingPlan 'Microsoft.DesktopVirtualization/scalingPlans@2024-04-03' = {
  name: name
  location: location
  tags: tags
  properties: {
    friendlyName: friendlyName
    description: 'Starts and stops the Linux Desktop session hosts on a schedule.'
    hostPoolType: 'Pooled'
    timeZone: timeZone
    exclusionTag: exclusionTag
    hostPoolReferences: enabled
      ? [
          {
            hostPoolArmPath: hostPool.id
            scalingPlanEnabled: true
          }
        ]
      : []
    schedules: [
      union(sharedScheduleSettings, {
        name: 'weekdays'
        daysOfWeek: [
          'Monday'
          'Tuesday'
          'Wednesday'
          'Thursday'
          'Friday'
        ]
        rampUpMinimumHostsPct: rampUpMinimumHostsPct
        rampDownMinimumHostsPct: rampDownMinimumHostsPct
      })
      union(sharedScheduleSettings, {
        name: 'weekend'
        daysOfWeek: [
          'Saturday'
          'Sunday'
        ]
        rampUpMinimumHostsPct: weekendMinimumHostsPct
        rampDownMinimumHostsPct: weekendMinimumHostsPct
      })
    ]
  }
}

output name string = scalingPlan.name
output id string = scalingPlan.id
