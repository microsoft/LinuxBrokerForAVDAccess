using System.Text.Json.Nodes;

namespace LinuxBroker.Launcher.Tests;

public sealed class ConfigurationTests
{
    [Theory]
    [InlineData("https://login.microsoftonline.com")]
    [InlineData("https://login.microsoftonline.us/")]
    [InlineData("https://login.chinacloudapi.cn/")]
    [InlineData("https://login.custom.example")]
    [InlineData("https://login.identity.sovereign.example/")]
    public void Tenant_cloud_scope_and_wam_redirect_are_explicit(string authority)
    {
        JsonNode config = JsonNode.Parse(TestData.ConfigJson)!;
        config["authorityHost"] = authority;
        LauncherConfiguration parsed = LauncherConfiguration.Parse(config.ToJsonString());
        Assert.Equal($"{authority.TrimEnd('/')}/{TestData.Tenant}", parsed.Authority.AbsoluteUri);
        Assert.Equal($"api://{TestData.Api}/connect_as_user", parsed.Scope);
        Assert.Equal($"ms-appx-web://microsoft.aad.brokerplugin/{TestData.Client}", parsed.RedirectUri);
        Assert.Equal("https://broker.example.test/api/vms/checkout", parsed.CheckoutUri.AbsoluteUri);
        var application = MsalClient.CreateApplication(parsed, () => new nint(123));
        Assert.Equal(TestData.Client, application.AppConfig.ClientId);
        Assert.Equal(parsed.RedirectUri, application.AppConfig.RedirectUri);
        Assert.Equal(parsed.Authority.AbsoluteUri, application.Authority.TrimEnd('/'));
    }

    [Fact]
    public void Explicit_custom_authority_accepts_the_standard_https_port()
    {
        JsonNode config = JsonNode.Parse(TestData.ConfigJson)!;
        config["authorityHost"] = "https://login.custom.example:443/";
        LauncherConfiguration parsed = LauncherConfiguration.Parse(config.ToJsonString());
        Assert.Equal($"https://login.custom.example/{TestData.Tenant}", parsed.Authority.AbsoluteUri);
    }

    [Theory]
    [InlineData("tenantId", "common")]
    [InlineData("tenantId", "organizations")]
    [InlineData("tenantId", "00000000-0000-0000-0000-000000000000")]
    [InlineData("clientId", "")]
    [InlineData("clientId", TestData.Api)]
    [InlineData("apiClientId", "not-an-app-id")]
    [InlineData("authorityHost", "http://login.microsoftonline.com")]
    [InlineData("authorityHost", "https://login.microsoftonline.com/common")]
    [InlineData("authorityHost", "https://login.microsoftonline.com/organizations")]
    [InlineData("authorityHost", "https://login.microsoftonline.com:444")]
    [InlineData("authorityHost", "https://login.microsoftonline.com@evil.example")]
    [InlineData("authorityHost", "https://user@login.microsoftonline.com")]
    [InlineData("authorityHost", "https://login.microsoftonline.com/?x=1")]
    [InlineData("authorityHost", "https://@login.custom.example")]
    [InlineData("authorityHost", "https://localhost")]
    [InlineData("authorityHost", "https://LOCALHOST./")]
    [InlineData("authorityHost", "https://login.localhost/")]
    [InlineData("authorityHost", "https://127.0.0.1")]
    [InlineData("authorityHost", "https://10.2.3.4")]
    [InlineData("authorityHost", "https://2130706433")]
    [InlineData("authorityHost", "https://[::1]")]
    [InlineData("authorityHost", "https://[2001:db8::1]")]
    [InlineData("authorityHost", "https://-login.example")]
    [InlineData("authorityHost", "https://login..example")]
    [InlineData("authorityHost", "http://login.custom.example")]
    [InlineData("authorityHost", "https://login.custom.example:8443")]
    [InlineData("authorityHost", "https://login.custom.example/tenant")]
    [InlineData("authorityHost", "https://login.custom.example/tenant/..")]
    [InlineData("authorityHost", "https://login.custom.example/./")]
    [InlineData("authorityHost", "https://login.custom.example/%2e/")]
    [InlineData("authorityHost", "https://login.custom.example//")]
    [InlineData("authorityHost", "https://login.custom.example/?")]
    [InlineData("authorityHost", "https://login.custom.example/#fragment")]
    [InlineData("authorityHost", "https://login.custom.example\\")]
    [InlineData("authorityHost", "https://login.custom.example\r\n")]
    [InlineData("apiBaseUrl", "http://broker.example.test/api")]
    [InlineData("apiBaseUrl", "https://broker.example.test")]
    [InlineData("apiBaseUrl", "https://broker.example.test/api/")]
    [InlineData("apiBaseUrl", "https://broker.example.test/api?other=/api")]
    [InlineData("apiBaseUrl", "https://broker.example.test/api#")]
    [InlineData("apiBaseUrl", "https://user:password@broker.example.test/api")]
    [InlineData("apiBaseUrl", "https://localhost/api")]
    [InlineData("apiBaseUrl", "https://broker.example.test\\api")]
    public void Invalid_configuration_is_rejected(string key, string value)
    {
        JsonNode config = JsonNode.Parse(TestData.ConfigJson)!;
        config[key] = value;
        Assert.Equal(LauncherError.Configuration, Assert.Throws<LauncherException>(() =>
            LauncherConfiguration.Parse(config.ToJsonString())).Error);
    }

    [Fact]
    public void Missing_extra_duplicate_and_nonstring_fields_fail_closed()
    {
        JsonObject config = JsonNode.Parse(TestData.ConfigJson)!.AsObject();
        config.Remove("tenantId");
        Assert.Throws<LauncherException>(() => LauncherConfiguration.Parse(config.ToJsonString()));
        config = JsonNode.Parse(TestData.ConfigJson)!.AsObject();
        config["clientSecret"] = "must-never-be-configured";
        Assert.Throws<LauncherException>(() => LauncherConfiguration.Parse(config.ToJsonString()));
        config = JsonNode.Parse(TestData.ConfigJson)!.AsObject();
        config["tenantId"] = 42;
        Assert.Throws<LauncherException>(() => LauncherConfiguration.Parse(config.ToJsonString()));
        string duplicate = TestData.ConfigJson.Replace("{", """{"tenantId":"duplicated",""");
        Assert.Throws<LauncherException>(() => LauncherConfiguration.Parse(duplicate));
        Assert.Throws<LauncherException>(() => LauncherConfiguration.Parse("[]"));
        Assert.Throws<LauncherException>(() => LauncherConfiguration.Parse("{broken"));
    }

    [Fact]
    public void Exact_command_line_allows_spaces_in_absolute_config_path()
    {
        LauncherArguments arguments = LauncherArguments.Parse(["--config", @"C:\Program Files\Linux Broker\launcher.json", "--mode", "DESKTOP"]);
        Assert.Equal("desktop", arguments.Mode);
        Assert.Equal(@"C:\Program Files\Linux Broker\launcher.json", arguments.ConfigPath);
    }

    [Theory]
    [InlineData("launcher.json")]
    [InlineData(@"C:launcher.json")]
    [InlineData(@"\\host\share\launcher.json")]
    [InlineData("C:\\bad\nname.json")]
    [InlineData("C:\\bad\"name.json")]
    public void Nonlocal_or_ambiguous_paths_are_rejected(string path)
    {
        Assert.Throws<LauncherException>(() => LauncherArguments.Parse(["--config", path, "--mode", "desktop"]));
    }

    [Fact]
    public void Unsupported_mode_is_rejected_before_configuration_loading()
    {
        LauncherException error = Assert.Throws<LauncherException>(() =>
            LauncherArguments.Parse(["--config", "missing.json", "--mode", "xpra"]));
        Assert.Equal(LauncherError.UnsupportedMode, error.Error);
    }

    [Fact]
    public void No_username_argument_or_duplicate_flag_is_accepted()
    {
        Assert.Throws<LauncherException>(() => LauncherArguments.Parse(["--username", "victim", "--mode", "desktop"]));
        Assert.Throws<LauncherException>(() => LauncherArguments.Parse(["--config", @"C:\a.json", "--config", @"C:\b.json"]));
        Assert.Throws<LauncherException>(() => LauncherArguments.Parse(["--config", @"C:\a.json"]));
    }
}
