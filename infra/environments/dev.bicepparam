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

// Azure SQL Database free offer: 100,000 vCore seconds, 32 GB of data and
// 32 GB of backup a month, at no cost. AutoPause stops the database for the
// rest of the calendar month once the allowance runs out rather than billing
// the overage, so dev can never generate a bill. That option constrains the
// database to at most 4 vCores with local-redundant backups and 7-day
// point-in-time restore, which the settings above already satisfy -- raising
// sqlMaxVCores past 4 or moving sqlBackupStorageRedundancy off Local will make
// the deployment fail.
//
// Azure cannot convert an existing database to the free offer. If the dev
// database is already deployed, it has to be dropped and recreated for this to
// take effect.
param sqlUseFreeLimit = true
param sqlFreeLimitExhaustionBehavior = 'AutoPause'

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
