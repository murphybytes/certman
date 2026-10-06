using '../main.bicep'

param environmentName = 'dev'

param vnetAddressPrefix = '10.10.0.0/16'
param privateEndpointsSubnetPrefix = '10.10.1.0/24'
param functionsSubnetPrefix = '10.10.2.0/24'

// Public access stays on so developers can connect after adding a firewall
// rule for their IP; Entra-only auth is still enforced.
param sqlPublicNetworkAccess = 'Enabled'

// IPv4 CIDR blocks allowed to reach the SQL server, e.g.
//   { name: 'office', cidr: '198.51.100.0/24' }
// The rule 0.0.0.0/32 allows access from Azure services.
param sqlFirewallRules = [
  { name: 'dev-workstation', cidr: '73.37.174.38/32' }
]

param sqlMaxVCores = 2
param sqlMinVCores = '0.5'
param sqlAutoPauseDelayMinutes = 60
param sqlBackupStorageRedundancy = 'Local'

// Entra users (by user principal name) in this environment's SQL groups.
// Deploying replaces each group's membership with these lists, so people
// added to the groups by hand are removed on the next deploy.
param sqlAdminMemberUpns = [
  'murphybytes_gmail.com#EXT#@murphybytesgmail.onmicrosoft.com'
]
param sqlUserMemberUpns = []

// Function app scale-out limit and per-instance memory (512, 2048 or 4096 MB).
param functionMaximumInstanceCount = 10
param functionInstanceMemoryMB = 2048
