# Pester 5 tests for avd_host/broker/Connect-LinuxBroker.ps1, which runs in Windows PowerShell 5.1
# on the AVD session hosts. From the repository root, in Windows PowerShell:
#   Invoke-Pester -Path avd_host/tests

BeforeAll {
    $script:BrokerScriptPath = (Resolve-Path (Join-Path $PSScriptRoot '..\broker\Connect-LinuxBroker.ps1')).Path
    . $script:BrokerScriptPath

    Add-Type -AssemblyName System.Net.Http
    if (-not ('LinuxBrokerTests.StubHandler' -as [type])) {
        Add-Type -ReferencedAssemblies System.Net.Http -TypeDefinition @'
namespace LinuxBrokerTests
{
    using System.Net;
    using System.Net.Http;
    using System.Threading;
    using System.Threading.Tasks;

    // Answers every request HttpClient sends with the response it is set up with.
    public class StubHandler : HttpMessageHandler
    {
        public HttpStatusCode StatusCode = HttpStatusCode.OK;
        public string ResponseBody = "";
        public string RetryAfter;
        public string Failure;
        public bool Cancel;
        public bool Hang;
        public int DelayMilliseconds;
        public int Calls;
        public HttpRequestMessage LastRequest;
        public string LastBody;
        public string LastContentType;

        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Calls++;
            LastRequest = request;
            if (request.Content != null)
            {
                LastBody = request.Content.ReadAsStringAsync().Result;
                LastContentType = request.Content.Headers.ContentType.MediaType;
            }

            var source = new TaskCompletionSource<HttpResponseMessage>();
            if (Hang)
            {
                return source.Task;
            }
            if (Failure != null)
            {
                source.SetException(new HttpRequestException(Failure));
                return source.Task;
            }
            if (Cancel)
            {
                source.SetCanceled();
                return source.Task;
            }

            var response = new HttpResponseMessage(StatusCode);
            response.Content = new StringContent(ResponseBody ?? "", System.Text.Encoding.UTF8, "application/json");
            if (RetryAfter != null)
            {
                response.Headers.TryAddWithoutValidation("Retry-After", RetryAfter);
            }
            response.RequestMessage = request;
            if (DelayMilliseconds > 0)
            {
                return Task.Delay(DelayMilliseconds).ContinueWith(delay => response);
            }
            source.SetResult(response);
            return source.Task;
        }
    }
}
'@
    }

    function New-TestResponse {
        param(
            [int]$StatusCode,
            $Body = $null,
            $RetryAfter = $null,
            [string]$Message = $null,
            [switch]$Cancelled
        )

        [pscustomobject]@{
            StatusCode = $StatusCode
            Body       = $Body
            RetryAfter = $RetryAfter
            Error      = $Message
            Cancelled  = [bool]$Cancelled
        }
    }

    function New-TestCheckout {
        [pscustomobject]@{ VMID = 5; Hostname = 'lnx-05'; IPAddress = '10.0.0.5'; LeaseId = 'lease'; Password = 'from-the-broker' }
    }

    function New-TestStarting {
        param($RetryAfter = 60, [string]$Reason = 'Started')

        New-TestResponse -StatusCode 202 -RetryAfter $RetryAfter -Body ([pscustomobject]@{
                status            = 'Starting'
                reason            = $Reason
                retryAfterSeconds = $RetryAfter
                message           = "A Linux host is starting for you. Ask again in $RetryAfter seconds."
            })
    }
}

Describe 'Connect-LinuxBroker.ps1' {
    BeforeAll {
        $script:Content = [System.IO.File]::ReadAllText($script:BrokerScriptPath)
    }

    It 'is plain ASCII, because it is installed without a byte order mark and Windows PowerShell reads it as ANSI' {
        $bytes = [System.IO.File]::ReadAllBytes($script:BrokerScriptPath)
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
    }

    It 'parses' {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($script:BrokerScriptPath, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    # Configure-AVD-Host.ps1 replaces every occurrence of each, so any other mention would be
    # rewritten too.
    It 'names each value filled in at installation exactly once' {
        [regex]::Matches($script:Content, [regex]::Escape('https://your_linuxbroker_api_base_url/api')).Count | Should -Be 1
        [regex]::Matches($script:Content, [regex]::Escape('your_linuxbroker_api_client_id')).Count | Should -Be 1
    }

    It 'takes the API URL and client ID the way Configure-AVD-Host.ps1 fills them in' {
        $installed = ($script:Content -replace 'https://your_linuxbroker_api_base_url/api', 'https://broker.example/api').Replace(
            'your_linuxbroker_api_client_id', '11111111-2222-3333-4444-555555555555')

        $installed | Should -Match ([regex]::Escape('$apiBaseUrl = "https://broker.example/api"'))
        $installed | Should -Match ([regex]::Escape('$apiAppIdUri = "api://11111111-2222-3333-4444-555555555555"'))
        $installed | Should -Not -Match 'your_linuxbroker'
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($installed, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    # The same rule as CLIENT_VERSION_RE and CLIENT_VERSION_MAX_CHARS in api/app.py.
    It 'reports a version the broker records' {
        $ScriptVersion | Should -Match '^[A-Za-z0-9][A-Za-z0-9._+-]*$'
        $ScriptVersion.Length | Should -BeLessOrEqual 32
    }

    It 'waits ten minutes at most by default' {
        $MaxWaitSeconds | Should -Be 600
    }
}

Describe 'ConvertTo-RetryAfter' {
    It 'reads <Value> as <Expected>' -TestCases @(
        @{ Value = 45; Expected = 45 }
        @{ Value = '45'; Expected = 45 }
        @{ Value = ' 30 '; Expected = 30 }
        @{ Value = @('75', '10'); Expected = 75 }
    ) {
        ConvertTo-RetryAfter $Value | Should -Be $Expected
    }

    It 'returns nothing for <Value>' -TestCases @(
        @{ Value = $null }
        @{ Value = '' }
        @{ Value = 'soon' }
        @{ Value = '4.5' }
        @{ Value = @() }
    ) {
        ConvertTo-RetryAfter $Value | Should -BeNullOrEmpty
    }
}

Describe 'Get-RetryDelay' {
    It 'waits what the broker asks for, from 5 to 120 seconds: <RetryAfter> gives <Expected>' -TestCases @(
        @{ RetryAfter = 60; Expected = 60 }
        @{ RetryAfter = 1; Expected = 5 }
        @{ RetryAfter = 0; Expected = 5 }
        @{ RetryAfter = 600; Expected = 120 }
    ) {
        Get-RetryDelay -RetryAfter $RetryAfter -WaitCount 3 | Should -Be $Expected
    }

    It 'waits 30, 30, then 60 seconds when the broker does not say' {
        0..5 | ForEach-Object { Get-RetryDelay -RetryAfter $null -WaitCount $_ } | Should -Be @(30, 30, 60, 60, 60, 60)
    }
}

Describe 'Test-TransientFailure' {
    It 'retries <StatusCode>' -TestCases @(
        @{ StatusCode = 0 }, @{ StatusCode = 408 }, @{ StatusCode = 429 }, @{ StatusCode = 500 }, @{ StatusCode = 502 }, @{ StatusCode = 503 }
    ) {
        Test-TransientFailure -StatusCode $StatusCode | Should -BeTrue
    }

    It 'does not retry <StatusCode>' -TestCases @(
        @{ StatusCode = 200 }, @{ StatusCode = 202 }, @{ StatusCode = 400 }, @{ StatusCode = 401 }, @{ StatusCode = 403 }, @{ StatusCode = 404 }, @{ StatusCode = 409 }
    ) {
        Test-TransientFailure -StatusCode $StatusCode | Should -BeFalse
    }
}

Describe 'Invoke-BrokerCheckout' {
    BeforeEach {
        Mock Write-Log {}
        Mock Invoke-WindowMessagePump {}
        $handler = New-Object LinuxBrokerTests.StubHandler
        $client = New-Object System.Net.Http.HttpClient -ArgumentList $handler
        $checkoutRequest = @{
            Client      = $client
            Url         = 'https://broker.example/api/vms/checkout'
            AccessToken = 'token-1'
            Body        = @{ username = 'alice'; avdhost = 'avd-0'; clientVersion = '2.0.0' }
        }
    }

    AfterEach {
        $client.Dispose()
    }

    It 'posts the checkout as JSON with the bearer token' {
        $handler.ResponseBody = '{"VMID": 5, "Hostname": "lnx-05", "IPAddress": "10.0.0.5", "LeaseId": "lease"}'

        $response = Invoke-BrokerCheckout @checkoutRequest

        $response.StatusCode | Should -Be 200
        $response.Body.Hostname | Should -Be 'lnx-05'
        $response.Body.IPAddress | Should -Be '10.0.0.5'
        $response.Error | Should -BeNullOrEmpty
        $response.Cancelled | Should -BeFalse
        $handler.Calls | Should -Be 1
        $handler.LastRequest.Method.Method | Should -Be 'POST'
        $handler.LastRequest.RequestUri.AbsoluteUri | Should -Be 'https://broker.example/api/vms/checkout'
        $handler.LastRequest.Headers.Authorization.Scheme | Should -Be 'Bearer'
        $handler.LastRequest.Headers.Authorization.Parameter | Should -Be 'token-1'
        $handler.LastContentType | Should -Be 'application/json'
        $sent = $handler.LastBody | ConvertFrom-Json
        $sent.username | Should -Be 'alice'
        $sent.avdhost | Should -Be 'avd-0'
        $sent.clientVersion | Should -Be '2.0.0'
    }

    It 'reads the wait from a 202 body' {
        $handler.StatusCode = [System.Net.HttpStatusCode]::Accepted
        $handler.RetryAfter = '90'
        $handler.ResponseBody = '{"status": "Starting", "reason": "Started", "retryAfterSeconds": 75, "message": "A Linux host is starting for you."}'

        $response = Invoke-BrokerCheckout @checkoutRequest

        $response.StatusCode | Should -Be 202
        $response.RetryAfter | Should -Be 75
        $response.Body.reason | Should -Be 'Started'
    }

    It 'reads the wait from the Retry-After header when the body has none' {
        $handler.StatusCode = [System.Net.HttpStatusCode]::Accepted
        $handler.RetryAfter = '40'
        $handler.ResponseBody = '{"status": "Starting"}'

        (Invoke-BrokerCheckout @checkoutRequest).RetryAfter | Should -Be 40
    }

    It 'reports the error the broker gives' {
        $handler.StatusCode = [System.Net.HttpStatusCode]::Conflict
        $handler.ResponseBody = '{"error": "No available VM found. Please try again."}'

        $response = Invoke-BrokerCheckout @checkoutRequest

        $response.StatusCode | Should -Be 409
        $response.Error | Should -Be 'No available VM found. Please try again.'
        $response.RetryAfter | Should -BeNullOrEmpty
    }

    It 'reports an answer that is not JSON' {
        $handler.StatusCode = [System.Net.HttpStatusCode]::BadGateway
        $handler.ResponseBody = '<html>Bad gateway</html>'

        $response = Invoke-BrokerCheckout @checkoutRequest

        $response.StatusCode | Should -Be 502
        $response.Body | Should -BeNullOrEmpty
        $response.Error | Should -Match 'not JSON'
    }

    It 'reports no status when the request fails' {
        $handler.Failure = 'No such host is known.'

        $response = Invoke-BrokerCheckout @checkoutRequest

        $response.StatusCode | Should -Be 0
        $response.Error | Should -Match 'No such host is known'
    }

    It 'reports no status when the broker does not answer in time' {
        $handler.Cancel = $true

        $response = Invoke-BrokerCheckout @checkoutRequest

        $response.StatusCode | Should -Be 0
        $response.Error | Should -Match 'did not answer within 120 seconds'
        $response.Cancelled | Should -BeFalse
    }

    It 'keeps the wait window responsive while the request runs' {
        $handler.DelayMilliseconds = 400
        $handler.ResponseBody = '{"VMID": 5, "Hostname": "lnx-05", "IPAddress": "10.0.0.5"}'

        $response = Invoke-BrokerCheckout @checkoutRequest -WaitWindow ([pscustomobject]@{ Cancelled = $false })

        $response.StatusCode | Should -Be 200
        Should -Invoke Invoke-WindowMessagePump -Scope It
    }

    It 'abandons the request when the user cancels' {
        $handler.Hang = $true

        $response = Invoke-BrokerCheckout @checkoutRequest -WaitWindow ([pscustomobject]@{ Cancelled = $true })

        $response.Cancelled | Should -BeTrue
        $response.StatusCode | Should -Be 0
    }
}

Describe 'Wait-CheckoutInterval' {
    BeforeEach {
        $script:Clock = 100.0
        Mock Get-MonotonicTime { $script:Clock }
        Mock Start-Sleep { $script:Clock += $Milliseconds / 1000.0 }
        Mock Invoke-WindowMessagePump {}
    }

    It 'waits the whole interval, keeping the window responsive' {
        Wait-CheckoutInterval -Seconds 2 -WaitWindow ([pscustomobject]@{ Cancelled = $false }) | Should -BeTrue
        $script:Clock | Should -BeGreaterOrEqual 102
        $script:Clock | Should -BeLessThan 102.2
        Should -Invoke Invoke-WindowMessagePump -Scope It -Times 19
    }

    It 'stops as soon as the user cancels' {
        $script:Window = [pscustomobject]@{ Cancelled = $false }
        Mock Start-Sleep {
            $script:Clock += $Milliseconds / 1000.0
            if ($script:Clock -ge 100.5) { $script:Window.Cancelled = $true }
        }

        Wait-CheckoutInterval -Seconds 60 -WaitWindow $script:Window | Should -BeFalse
        $script:Clock | Should -BeLessThan 101
    }

    It 'waits without a window' {
        Wait-CheckoutInterval -Seconds 1 | Should -BeTrue
        $script:Clock | Should -BeGreaterOrEqual 101
    }
}

Describe 'Request-LinuxHost' {
    BeforeEach {
        $script:Responses = New-Object System.Collections.Queue
        $script:Clock = 0.0
        $script:Waited = New-Object System.Collections.ArrayList
        $script:Tokens = New-Object System.Collections.Queue
        $script:Tokens.Enqueue('token-1')
        $script:Tokens.Enqueue('token-2')
        $script:Window = [pscustomobject]@{ Form = $null; Cancelled = $false; Closing = $false }

        Mock Write-Log {}
        Mock Get-AccessToken { if ($script:Tokens.Count -gt 0) { $script:Tokens.Dequeue() } }
        Mock New-BrokerHttpClient { [pscustomobject]@{ Name = 'client' } }
        Mock Invoke-BrokerCheckout { $script:Responses.Dequeue() }
        Mock Open-WaitWindow { $script:Window }
        Mock Close-WaitWindow {}
        Mock Get-MonotonicTime { $script:Clock }
        Mock Wait-CheckoutInterval {
            [void]$script:Waited.Add([double]$Seconds)
            $script:Clock += $Seconds
            $true
        }

        $requestArguments = @{
            CheckoutUrl = 'https://broker.example/api/vms/checkout'
            Resource    = 'api://client'
            Username    = 'alice'
            AvdHost     = 'avd-0'
        }
    }

    It 'returns the host from a 200 without showing the wait window' {
        $script:Responses.Enqueue((New-TestResponse -StatusCode 200 -Body (New-TestCheckout)))

        $result = Request-LinuxHost @requestArguments

        $result.Outcome | Should -Be 'Assigned'
        $result.Checkout.Hostname | Should -Be 'lnx-05'
        Should -Invoke Get-AccessToken -Scope It -Times 1 -Exactly -ParameterFilter { $Resource -eq 'api://client' }
        Should -Invoke Invoke-BrokerCheckout -Scope It -Times 1 -Exactly -ParameterFilter {
            $Url -eq 'https://broker.example/api/vms/checkout' -and $AccessToken -eq 'token-1' -and
            $Body.username -eq 'alice' -and $Body.avdhost -eq 'avd-0' -and $Body.clientVersion -eq $ScriptVersion
        }
        Should -Invoke Open-WaitWindow -Scope It -Times 0 -Exactly
        Should -Invoke Wait-CheckoutInterval -Scope It -Times 0 -Exactly
    }

    It 'does not ask the broker without an access token' {
        $script:Tokens.Clear()

        (Request-LinuxHost @requestArguments).Outcome | Should -Be 'AuthFailed'
        Should -Invoke Invoke-BrokerCheckout -Scope It -Times 0 -Exactly
    }

    It 'shows the wait window and asks again when the broker says, until the host is ready' {
        $script:Responses.Enqueue((New-TestStarting -RetryAfter 75))
        $script:Responses.Enqueue((New-TestStarting -RetryAfter 30 -Reason 'AlreadyStarting'))
        $script:Responses.Enqueue((New-TestResponse -StatusCode 200 -Body (New-TestCheckout)))

        $result = Request-LinuxHost @requestArguments

        $result.Outcome | Should -Be 'Assigned'
        $script:Waited | Should -Be @(75, 30)
        Should -Invoke Open-WaitWindow -Scope It -Times 1 -Exactly
        Should -Invoke Invoke-BrokerCheckout -Scope It -Times 3 -Exactly
        Should -Invoke Invoke-BrokerCheckout -Scope It -Times 2 -Exactly -ParameterFilter { $null -ne $WaitWindow }
        Should -Invoke Close-WaitWindow -Scope It -Times 1 -Exactly -ParameterFilter { $null -ne $WaitWindow }
    }

    It 'waits 30, 30, then 60 seconds when the broker does not say how long' {
        1..5 | ForEach-Object { $script:Responses.Enqueue((New-TestResponse -StatusCode 202 -Body ([pscustomobject]@{ status = 'Starting' }))) }
        $script:Responses.Enqueue((New-TestResponse -StatusCode 200 -Body (New-TestCheckout)))

        (Request-LinuxHost @requestArguments).Outcome | Should -Be 'Assigned'
        $script:Waited | Should -Be @(30, 30, 60, 60, 60)
    }

    It 'gives up after MaxWaitSeconds, asking one last time at the deadline' {
        1..10 | ForEach-Object { $script:Responses.Enqueue((New-TestStarting -RetryAfter 120)) }

        $result = Request-LinuxHost @requestArguments -MaxWaitSeconds 300

        $result.Outcome | Should -Be 'TimedOut'
        $script:Waited | Should -Be @(120, 120, 60)
        Should -Invoke Invoke-BrokerCheckout -Scope It -Times 4 -Exactly
        Should -Invoke Close-WaitWindow -Scope It -Times 1 -Exactly -ParameterFilter { $null -ne $WaitWindow }
    }

    It 'asks again within two minutes, however long the broker asks it to wait' {
        $script:Responses.Enqueue((New-TestStarting -RetryAfter 900))
        $script:Responses.Enqueue((New-TestResponse -StatusCode 200 -Body (New-TestCheckout)))

        (Request-LinuxHost @requestArguments).Outcome | Should -Be 'Assigned'
        $script:Waited | Should -Be @(120)
    }

    It 'does not wait when MaxWaitSeconds is 0' {
        $script:Responses.Enqueue((New-TestStarting))

        (Request-LinuxHost @requestArguments -MaxWaitSeconds 0).Outcome | Should -Be 'Starting'
        Should -Invoke Open-WaitWindow -Scope It -Times 0 -Exactly
        Should -Invoke Wait-CheckoutInterval -Scope It -Times 0 -Exactly
    }

    It 'stops when the user cancels the wait' {
        $script:Responses.Enqueue((New-TestStarting))
        Mock Wait-CheckoutInterval { $false }

        (Request-LinuxHost @requestArguments).Outcome | Should -Be 'Cancelled'
        Should -Invoke Invoke-BrokerCheckout -Scope It -Times 1 -Exactly
        Should -Invoke Close-WaitWindow -Scope It -Times 1 -Exactly -ParameterFilter { $null -ne $WaitWindow }
    }

    It 'stops when the user cancels during a request' {
        $script:Responses.Enqueue((New-TestStarting))
        $script:Responses.Enqueue((New-TestResponse -StatusCode 0 -Cancelled))

        (Request-LinuxHost @requestArguments).Outcome | Should -Be 'Cancelled'
    }

    It 'waits with no window when it cannot be shown' {
        Mock Open-WaitWindow { $null }
        $script:Responses.Enqueue((New-TestStarting -RetryAfter 45))
        $script:Responses.Enqueue((New-TestResponse -StatusCode 200 -Body (New-TestCheckout)))

        (Request-LinuxHost @requestArguments).Outcome | Should -Be 'Assigned'
        $script:Waited | Should -Be @(45)
    }

    It 'reports that no host is available on a 409' {
        $script:Responses.Enqueue((New-TestResponse -StatusCode 409 -Message 'No available VM found. Please try again.'))

        (Request-LinuxHost @requestArguments).Outcome | Should -Be 'NoHost'
        Should -Invoke Invoke-BrokerCheckout -Scope It -Times 1 -Exactly
    }

    It 'renews a refused access token once' {
        $script:Responses.Enqueue((New-TestResponse -StatusCode 401 -Message 'Token is invalid.'))
        $script:Responses.Enqueue((New-TestResponse -StatusCode 200 -Body (New-TestCheckout)))

        (Request-LinuxHost @requestArguments).Outcome | Should -Be 'Assigned'
        Should -Invoke Get-AccessToken -Scope It -Times 2 -Exactly
        Should -Invoke Invoke-BrokerCheckout -Scope It -Times 1 -Exactly -ParameterFilter { $AccessToken -eq 'token-2' }
    }

    It 'gives up when the renewed token is refused too' {
        $script:Responses.Enqueue((New-TestResponse -StatusCode 401))
        $script:Responses.Enqueue((New-TestResponse -StatusCode 401))

        (Request-LinuxHost @requestArguments).Outcome | Should -Be 'AuthFailed'
        Should -Invoke Invoke-BrokerCheckout -Scope It -Times 2 -Exactly
    }

    It 'gives up when the session host is not allowed to check out' {
        $script:Responses.Enqueue((New-TestResponse -StatusCode 403 -Message 'Forbidden'))

        (Request-LinuxHost @requestArguments).Outcome | Should -Be 'AuthFailed'
        Should -Invoke Get-AccessToken -Scope It -Times 1 -Exactly
    }

    It 'retries a failed request after 5, then 10 seconds' {
        $script:Responses.Enqueue((New-TestResponse -StatusCode 500 -Message 'Unable to check out a virtual machine.'))
        $script:Responses.Enqueue((New-TestResponse -StatusCode 0 -Message 'Unable to connect to the remote server'))
        $script:Responses.Enqueue((New-TestResponse -StatusCode 200 -Body (New-TestCheckout)))

        (Request-LinuxHost @requestArguments).Outcome | Should -Be 'Assigned'
        $script:Waited | Should -Be @(5, 10)
        Should -Invoke Open-WaitWindow -Scope It -Times 0 -Exactly
    }

    It 'reports the broker as unavailable after three failures in a row' {
        1..3 | ForEach-Object { $script:Responses.Enqueue((New-TestResponse -StatusCode 503 -Message 'The broker is busy. Please retry shortly.')) }

        (Request-LinuxHost @requestArguments).Outcome | Should -Be 'Unavailable'
        Should -Invoke Invoke-BrokerCheckout -Scope It -Times 3 -Exactly
        $script:Waited | Should -Be @(5, 10)
    }

    It 'honours a Retry-After on a failure' {
        $script:Responses.Enqueue((New-TestResponse -StatusCode 429 -RetryAfter 20))
        $script:Responses.Enqueue((New-TestResponse -StatusCode 200 -Body (New-TestCheckout)))

        (Request-LinuxHost @requestArguments).Outcome | Should -Be 'Assigned'
        $script:Waited | Should -Be @(20)
    }

    It 'counts failures in a row only' {
        $script:Responses.Enqueue((New-TestResponse -StatusCode 500))
        $script:Responses.Enqueue((New-TestResponse -StatusCode 500))
        $script:Responses.Enqueue((New-TestStarting -RetryAfter 30))
        $script:Responses.Enqueue((New-TestResponse -StatusCode 500))
        $script:Responses.Enqueue((New-TestResponse -StatusCode 500))
        $script:Responses.Enqueue((New-TestResponse -StatusCode 200 -Body (New-TestCheckout)))

        (Request-LinuxHost @requestArguments).Outcome | Should -Be 'Assigned'
        $script:Waited | Should -Be @(5, 10, 30, 5, 10)
    }

    It 'does not retry failures past the wait deadline' {
        $script:Responses.Enqueue((New-TestStarting -RetryAfter 30))
        $script:Responses.Enqueue((New-TestResponse -StatusCode 500))

        (Request-LinuxHost @requestArguments -MaxWaitSeconds 30).Outcome | Should -Be 'TimedOut'
        $script:Waited | Should -Be @(30)
    }

    It 'refuses a checkout that names no address' {
        $script:Responses.Enqueue((New-TestResponse -StatusCode 200 -Body ([pscustomobject]@{ VMID = 5; Hostname = 'lnx-05'; IPAddress = $null })))

        (Request-LinuxHost @requestArguments).Outcome | Should -Be 'Rejected'
        Should -Invoke Invoke-BrokerCheckout -Scope It -Times 1 -Exactly
    }

    It 'gives up on a request the broker rejects: <StatusCode>' -TestCases @(
        @{ StatusCode = 400 }, @{ StatusCode = 404 }
    ) {
        $script:Responses.Enqueue((New-TestResponse -StatusCode $StatusCode -Message 'Rejected'))

        (Request-LinuxHost @requestArguments).Outcome | Should -Be 'Rejected'
        Should -Invoke Invoke-BrokerCheckout -Scope It -Times 1 -Exactly
    }
}

Describe 'Invoke-ConnectLinuxBroker' {
    BeforeEach {
        Mock Write-Log {}
        Mock Show-UserMessage {}
        Mock Save-LinuxHostCredential {}
        Mock Open-RemoteDesktop { $true }
        $connectArguments = @{
            ApiBaseUrl = 'https://broker.example/api'
            Resource   = 'api://client'
            Username   = 'alice'
            AvdHost    = 'avd-0'
        }
    }

    It 'saves the credentials and opens the desktop on the assigned host' {
        Mock Request-LinuxHost { New-CheckoutResult -Outcome Assigned -Checkout (New-TestCheckout) }

        Invoke-ConnectLinuxBroker @connectArguments | Should -Be 0
        Should -Invoke Request-LinuxHost -Scope It -Times 1 -Exactly -ParameterFilter {
            $CheckoutUrl -eq 'https://broker.example/api/vms/checkout' -and $Resource -eq 'api://client' -and
            $Username -eq 'alice' -and $AvdHost -eq 'avd-0' -and $MaxWaitSeconds -eq 600
        }
        Should -Invoke Save-LinuxHostCredential -Scope It -Times 1 -Exactly -ParameterFilter { $Username -eq 'alice' -and $Checkout.Hostname -eq 'lnx-05' }
        Should -Invoke Open-RemoteDesktop -Scope It -Times 1 -Exactly -ParameterFilter { $Hostname -eq 'lnx-05' -and $IPAddress -eq '10.0.0.5' }
        Should -Invoke Show-UserMessage -Scope It -Times 0 -Exactly
    }

    It 'passes MaxWaitSeconds on' {
        Mock Request-LinuxHost { New-CheckoutResult -Outcome Cancelled }

        Invoke-ConnectLinuxBroker @connectArguments -MaxWaitSeconds 120 | Should -Be 0
        Should -Invoke Request-LinuxHost -Scope It -Times 1 -Exactly -ParameterFilter { $MaxWaitSeconds -eq 120 }
    }

    It 'fails when Remote Desktop Connection cannot be started' {
        Mock Request-LinuxHost { New-CheckoutResult -Outcome Assigned -Checkout (New-TestCheckout) }
        Mock Open-RemoteDesktop { $false }

        Invoke-ConnectLinuxBroker @connectArguments | Should -Be 1
    }

    It 'closes quietly when the user cancels' {
        Mock Request-LinuxHost { New-CheckoutResult -Outcome Cancelled }

        Invoke-ConnectLinuxBroker @connectArguments | Should -Be 0
        Should -Invoke Show-UserMessage -Scope It -Times 0 -Exactly
        Should -Invoke Open-RemoteDesktop -Scope It -Times 0 -Exactly
    }

    It 'tells the user what happened: <Outcome>' -TestCases @(
        @{ Outcome = 'NoHost'; ExpectedText = 'No Linux host is available right now. Try again in a few minutes.'; ExpectedIcon = 'Warning' }
        @{ Outcome = 'Starting'; ExpectedText = 'A Linux host is starting for you. Try again in a few minutes.'; ExpectedIcon = 'Information' }
        @{ Outcome = 'TimedOut'; ExpectedText = 'Your Linux desktop is taking longer than usual to start. Try again in a few minutes.'; ExpectedIcon = 'Warning' }
        @{ Outcome = 'AuthFailed'; ExpectedText = 'The Linux Broker could not authenticate this session host. Contact your administrator.'; ExpectedIcon = 'Error' }
        @{ Outcome = 'Unavailable'; ExpectedText = 'The Linux Broker is not responding. Try again in a few minutes, or contact your administrator.'; ExpectedIcon = 'Error' }
        @{ Outcome = 'Rejected'; ExpectedText = 'The Linux Broker could not give you a Linux host. Contact your administrator.'; ExpectedIcon = 'Error' }
    ) {
        $script:Outcome = $Outcome
        Mock Request-LinuxHost { New-CheckoutResult -Outcome $script:Outcome }

        Invoke-ConnectLinuxBroker @connectArguments | Should -Be 1
        Should -Invoke Show-UserMessage -Scope It -Times 1 -Exactly -ParameterFilter { $Message -eq $ExpectedText -and $Icon -eq $ExpectedIcon }
        Should -Invoke Open-RemoteDesktop -Scope It -Times 0 -Exactly
    }

    It 'opens the desktop for any other mode, with a warning' {
        Mock Request-LinuxHost { New-CheckoutResult -Outcome Assigned -Checkout (New-TestCheckout) }

        Invoke-ConnectLinuxBroker @connectArguments -Mode 'xpra' | Should -Be 0
        Should -Invoke Write-Log -Scope It -Times 1 -Exactly -ParameterFilter { $Level -eq 'WARNING' -and $Message -like "Mode 'xpra' is not supported*" }
        Should -Invoke Open-RemoteDesktop -Scope It -Times 1 -Exactly
    }
}

Describe 'Save-LinuxHostCredential' {
    BeforeAll {
        # The CredentialManager module is installed on the session hosts only.
        if (-not (Get-Command New-StoredCredential -ErrorAction SilentlyContinue)) {
            function script:New-StoredCredential {
                param($Target, $UserName, $Password, $Type, $Persist)
            }
        }
    }

    BeforeEach {
        Mock Write-Log {}
        Mock cmdkey { 'Currently stored credentials:', '', '    Target: LegacyGeneric:target=lnx-01', '    Type: Generic' }
        Mock New-StoredCredential {}
    }

    It 'replaces every saved credential with the ones for the assigned host' {
        Save-LinuxHostCredential -Checkout (New-TestCheckout) -Username 'alice'

        Should -Invoke cmdkey -Scope It -Times 1 -Exactly -ParameterFilter { $args[0] -eq '/delete:LegacyGeneric:target=lnx-01' }
        foreach ($expected in 'lnx-05', '10.0.0.5') {
            Should -Invoke New-StoredCredential -Scope It -Times 1 -Exactly -ParameterFilter {
                $Target -eq $expected -and $UserName -eq 'alice' -and $Password -eq 'from-the-broker' -and $Persist -eq 'LocalMachine' -and -not $Type
            }
        }
        foreach ($expected in 'TERMSRV/lnx-05', 'TERMSRV/10.0.0.5') {
            Should -Invoke New-StoredCredential -Scope It -Times 1 -Exactly -ParameterFilter {
                $Target -eq $expected -and $UserName -eq 'alice' -and $Password -eq 'from-the-broker' -and $Persist -eq 'LocalMachine' -and $Type -eq 'Generic'
            }
        }
    }

    It 'still opens the desktop when the credentials cannot be saved' {
        Mock New-StoredCredential { throw 'Access is denied.' }

        { Save-LinuxHostCredential -Checkout (New-TestCheckout) -Username 'alice' } | Should -Not -Throw
        Should -Invoke Write-Log -Scope It -Times 1 -Exactly -ParameterFilter { $Level -eq 'ERROR' }
    }
}

Describe 'Open-RemoteDesktop' {
    BeforeEach {
        Mock Write-Log {}
        Mock Show-UserMessage {}
        Mock Test-Path { $true }
        Mock New-Item {}
        Mock New-ItemProperty {}
        Mock Start-Process {}
    }

    It 'turns off the server authentication warning and starts mstsc for the host' {
        Open-RemoteDesktop -Hostname 'lnx-05' -IPAddress '10.0.0.5' | Should -BeTrue

        Should -Invoke New-ItemProperty -Scope It -Times 1 -Exactly -ParameterFilter {
            $Path -eq 'HKCU:\Software\Microsoft\Terminal Server Client' -and $Name -eq 'AuthenticationLevelOverride' -and $Value -eq 0
        }
        Should -Invoke Start-Process -Scope It -Times 1 -Exactly -ParameterFilter { $FilePath -eq 'mstsc.exe' -and (@($ArgumentList) -join ' ') -eq '/v:10.0.0.5' }
        Should -Invoke New-Item -Scope It -Times 0 -Exactly
        Should -Invoke Show-UserMessage -Scope It -Times 0 -Exactly
    }

    It 'creates the Remote Desktop client key when it is missing' {
        Mock Test-Path { $false }

        Open-RemoteDesktop -Hostname 'lnx-05' -IPAddress '10.0.0.5' | Should -BeTrue
        Should -Invoke New-Item -Scope It -Times 1 -Exactly -ParameterFilter { $Path -eq 'HKCU:\Software\Microsoft\Terminal Server Client' }
    }

    It 'tells the user when mstsc cannot be started' {
        Mock Start-Process { throw 'The system cannot find the file specified.' }

        Open-RemoteDesktop -Hostname 'lnx-05' -IPAddress '10.0.0.5' | Should -BeFalse
        Should -Invoke Show-UserMessage -Scope It -Times 1 -Exactly -ParameterFilter {
            $Message -eq 'Remote Desktop Connection could not be started for lnx-05. Try again, or contact your administrator.' -and $Icon -eq 'Error'
        }
    }
}

# Needs a desktop to show the window on.
Describe 'Open-WaitWindow' -Skip:(-not [Environment]::UserInteractive) {
    BeforeEach {
        Mock Write-Log {}
    }

    It 'says the desktop is starting, and Cancel cancels the wait' {
        $window = Open-WaitWindow
        try {
            $window | Should -Not -BeNullOrEmpty
            $window.Form.Visible | Should -BeTrue
            $window.Form.Text | Should -Be 'Linux Desktop'
            $window.Cancelled | Should -BeFalse

            $window.Form.CancelButton.PerformClick()

            $window.Cancelled | Should -BeTrue
            $window.Form.IsDisposed | Should -BeTrue
        }
        finally {
            Close-WaitWindow -WaitWindow $window
        }
    }

    It 'counts closing the window as a cancel' {
        $window = Open-WaitWindow
        $window.Form.Close()

        $window.Cancelled | Should -BeTrue
    }

    It 'does not count closing it from the script as a cancel' {
        $window = Open-WaitWindow
        Close-WaitWindow -WaitWindow $window

        $window.Cancelled | Should -BeFalse
        $window.Form.IsDisposed | Should -BeTrue
        { Close-WaitWindow -WaitWindow $window } | Should -Not -Throw
    }
}
