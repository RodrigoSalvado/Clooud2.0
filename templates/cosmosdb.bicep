@description('Nome da Cosmos Account (globally unique). Se vazio, não cria Cosmos DB.')
param cosmosAccountName string = ''

@description('Localização para a Cosmos Account. Se não fornecido, usa a do resource group.')
param cosmosLocation string = resourceGroup().location

@description('Nome da base de dados SQL a criar (SQL API)')
param cosmosDatabaseName string = 'RedditApp'

@description('Nome do container na Cosmos DB')
param cosmosContainerName string = 'posts'

@description('Caminho da partition key, ex: \'/id\'')
param cosmosPartitionKeyPath string = '/id'

@description('Throughput manual para a base de dados (RU/s)')
@minValue(400)
param cosmosThroughput int = 400

// Cosmos Account
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
    // Se necessário, podes acrescentar networkAcls ou outras propriedades aqui
  }
}

// SQL Database dentro da Cosmos Account
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

// Container dentro da base de dados
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
