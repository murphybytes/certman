// Azure SQL logical server and database using Entra-only authentication,
// reachable from the virtual network through a private endpoint.

@export()
@description('An IPv4 address block allowed through the SQL server firewall.')
type firewallRule = {
  @description('Rule name, unique within the server.')
  name: string
  @description('IPv4 CIDR block, e.g. 203.0.113.10/32 for a single address or 198.51.100.0/24.')
  cidr: string
}

param location string
param serverName string
param databaseName string

@description('Display name of the Entra group that administers the server.')
param adminGroupName string

@description('Object ID of the Entra group that administers the server.')
param adminGroupObjectId string

@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string

@description('Firewall rules for public network access. Ignored by Azure while publicNetworkAccess is Disabled.')
param firewallRules firewallRule[] = []

param maxVCores int
param minVCores string
param autoPauseDelayMinutes int

@description('Whether the database uses the Azure SQL Database free offer: 100,000 vCore seconds of serverless compute, 32 GB of data and 32 GB of backup per month, for up to 10 General Purpose databases per subscription. Azure cannot convert an existing database to the free offer, so this must be set when the database is first created.')
param useFreeLimit bool = false

@description('What happens when the free monthly limit runs out. AutoPause stops the database until the next calendar month at no cost, but caps the database at 4 vCores and 32 GB with local-redundant backups and 7-day PITR. BillOverage keeps it running and bills the excess at standard serverless rates, and is a one-way door: Azure will not let it revert to AutoPause. Ignored when useFreeLimit is false.')
@allowed([
  'AutoPause'
  'BillOverage'
])
param freeLimitExhaustionBehavior string = 'AutoPause'

@allowed([
  'Local'
  'Zone'
  'Geo'
])
param backupStorageRedundancy string

param vnetId string
param privateEndpointsSubnetId string
param tags object

resource sqlServer 'Microsoft.Sql/servers@2023-08-01' = {
  name: serverName
  location: location
  tags: tags
  properties: {
    minimalTlsVersion: '1.2'
    publicNetworkAccess: publicNetworkAccess
    administrators: {
      administratorType: 'ActiveDirectory'
      azureADOnlyAuthentication: true
      principalType: 'Group'
      login: adminGroupName
      sid: adminGroupObjectId
      tenantId: tenant().tenantId
    }
  }
}

resource firewall 'Microsoft.Sql/servers/firewallRules@2023-08-01' = [
  for rule in firewallRules: {
    parent: sqlServer
    name: rule.name
    // Firewall rules take a start/end range; network..broadcast covers the whole block.
    properties: {
      startIpAddress: parseCidr(rule.cidr).network
      endIpAddress: parseCidr(rule.cidr).broadcast
    }
  }
]

resource database 'Microsoft.Sql/servers/databases@2023-08-01' = {
  parent: sqlServer
  name: databaseName
  location: location
  tags: tags
  sku: {
    name: 'GP_S_Gen5'
    tier: 'GeneralPurpose'
    family: 'Gen5'
    capacity: maxVCores
  }
  // freeLimitExhaustionBehavior is only sent when the free offer is on; Azure
  // rejects it on a database that isn't using the free limit.
  properties: {
    autoPauseDelay: autoPauseDelayMinutes
    minCapacity: json(minVCores)
    requestedBackupStorageRedundancy: backupStorageRedundancy
    zoneRedundant: false
    useFreeLimit: useFreeLimit
    ...(useFreeLimit ? { freeLimitExhaustionBehavior: freeLimitExhaustionBehavior } : {})
  }
}

var privateDnsZoneName = 'privatelink${environment().suffixes.sqlServerHostname}'

resource privateDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: privateDnsZoneName
  location: 'global'
  tags: tags
}

resource privateDnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: privateDnsZone
  name: '${last(split(vnetId, '/'))}-link'
  location: 'global'
  tags: tags
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: 'pe-${serverName}'
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointsSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: 'pe-${serverName}'
        properties: {
          privateLinkServiceId: sqlServer.id
          groupIds: [
            'sqlServer'
          ]
        }
      }
    ]
  }
}

resource privateDnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'sql'
        properties: {
          privateDnsZoneId: privateDnsZone.id
        }
      }
    ]
  }
}

output serverName string = sqlServer.name
output serverFqdn string = sqlServer.properties.fullyQualifiedDomainName
output databaseName string = database.name
