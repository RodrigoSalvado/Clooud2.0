@description('Nome da Cosmos Account (globalmente único). Se vazio, não cria.')
param cosmosAccountName string = ''

@description('Localização para a Cosmos Account (default: location do RG)')
param cosmosLocation string = resourceGroup().location

@description('Nome da base de dados SQL')
param cosmosDatabaseName string = 'RedditApp'

@description('Nome do container')
param cosmosContainerName string = 'posts'

@description('Partition key path, ex: \'/id\'')
param cosmosPartitionKeyPath string = '/id'

@description('Throughput (RU/s), mínimo 400')
@minValue(400)
param cosmosThroughput int = 400

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2021-04-15' = if (cosmosAccountName != '') {
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

resource cosmosSqlDb 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases@2021-04-15' = if (cosmosAccountName != '') {
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
}

resource cosmosContainer 'Microsoft.DocumentDB/databaseAccounts/sqlDatabases/containers@2021-04-15' = if (cosmosAccountName != '') {
  parent: cosmosSqlDb
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
    options: {}
  }
}
