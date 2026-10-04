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
  properties: {
    autoPauseDelay: autoPauseDelayMinutes
    minCapacity: json(minVCores)
    requestedBackupStorageRedundancy: backupStorageRedundancy
    zoneRedundant: false
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
