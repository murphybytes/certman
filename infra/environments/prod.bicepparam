using '../main.bicep'

param environmentName = 'prod'

param vnetAddressPrefix = '10.20.0.0/16'
param privateEndpointsSubnetPrefix = '10.20.1.0/24'

// Only reachable through the private endpoint.
param sqlPublicNetworkAccess = 'Disabled'

// Firewall rules have no effect while public network access is Disabled.
param sqlFirewallRules = []

param sqlMaxVCores = 4
param sqlMinVCores = '1'
param sqlAutoPauseDelayMinutes = -1
param sqlBackupStorageRedundancy = 'Geo'

// Entra users (by user principal name) in this environment's SQL groups.
// Deploying replaces each group's membership with these lists, so people
// added to the groups by hand are removed on the next deploy.
param sqlAdminMemberUpns = []
param sqlUserMemberUpns = []
