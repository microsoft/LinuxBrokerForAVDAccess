-- Assign a dedicated runtime database user to this role. Deployment uses a different,
-- privileged connection. Do not also grant that runtime user db_owner or schema-wide DML.
IF DATABASE_PRINCIPAL_ID('BrokerApiRuntime') IS NULL
    EXEC('CREATE ROLE BrokerApiRuntime AUTHORIZATION dbo');
GO
GRANT EXECUTE ON OBJECT::dbo.GetBrokerHost TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.BeginBrokerCheckout TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.ObserveBrokerSession TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.BeginBrokerCleanup TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.CompleteBrokerOperation TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.FailBrokerOperation TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.ReturnReleasedVms TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.AddVm TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.DeleteVm TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.UpdateVmAttributes TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.GetVms TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.GetVmDetails TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.GetVmSummary TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.GetVmHistory TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.GetVmHistoryPaged TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.TriggerScalingLogic TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.GetScalingRules TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.GetScalingRuleDetails TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.CreateScalingRule TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.UpdateScalingRule TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.DeleteScalingRule TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.GetScalingActivityLog TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.GetScalingActivityLogPaged TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.GetVMScalingRulesHistory TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.GetVmScalingRulesHistoryPaged TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.GetLinuxHostSettings TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.UpdateLinuxHostSettings TO BrokerApiRuntime;
GRANT EXECUTE ON OBJECT::dbo.RecordHostSettingsApplied TO BrokerApiRuntime;
DENY EXECUTE ON OBJECT::dbo.BindBrokerUser TO BrokerApiRuntime;
DENY EXECUTE ON OBJECT::dbo.RegisterBrokerHost TO BrokerApiRuntime;
DENY EXECUTE ON OBJECT::dbo.RegisterLinuxHostVm TO BrokerApiRuntime;
DENY EXECUTE ON OBJECT::dbo.GetBrokerLeaseMigrationState TO BrokerApiRuntime;
GO
