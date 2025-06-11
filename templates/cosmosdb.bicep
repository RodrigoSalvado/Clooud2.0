param cosmosAccountName string
param cosmosLocation string
param cosmosDatabaseName string
param cosmosContainerName string
param cosmosPartitionKeyPath string
param cosmosThroughput int
// location default do RG será usado no recurso pai se omitido

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2021-04-15' = {
  name: cosmosAccountName
  location: cosmosLocation
  kind: 'GlobalDocumentDB'
  properties: {
    databaseAccountOfferType: 'Standard'
    locations: [
      {
        locationName: cosmosLocation
        failoverPriority: 0
        isZoneRedundant: false
      }
    ]
    consistencyPolicy: {
      defaultConsistencyLevel: 'Session'
    }
  }
}

resource sqlDatabase 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2021-04-15' = {
  parent: cosmosAccount
  name: cosmosDatabaseName
  properties: {
    resource: {
      id: cosmosDatabaseName
    }
    options: {
      throughput: cosmosThroughput
    }
  }
  dependsOn: [
    cosmosAccount
  ]
}

resource sqlContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2021-04-15' = {
  parent: sqlDatabase
  name: cosmosContainerName
  properties: {
    resource: {
      id: cosmosContainerName
      partitionKey: {
        paths: [
          cosmosPartitionKeyPath
        ]
        kind: 'Hash'
      }
      indexingPolicy: {
        indexingMode: 'consistent'
      }
    }
    options: {
      // throughput específico se for o caso
    }
  }
  dependsOn: [
    sqlDatabase
  ]
}

output cosmosAccountEndpoint string = cosmosAccount.properties.documentEndpoint
output cosmosAccountKey string = listKeys(cosmosAccount.id, cosmosAccount.apiVersion).primaryMasterKey
