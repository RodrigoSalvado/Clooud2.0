@description('Nome do Function App')
param functionAppName string

@description('Nome da Storage Account existente para AzureWebJobsStorage (GPv2).')
param storageAccountName string

@description('Localização para o Function App e plano. Por padrão, usa resourceGroup().location')
param location string = resourceGroup().location

// Plano de Consumo para Function App (Linux Consumption)
resource functionPlan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: '${functionAppName}-plan'
  location: location
  kind: 'functionapp'
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true  // indica Linux
  }
}

// Referência à Storage Account existente, para obter a chave via resource symbol reference
resource storageAccountExisting 'Microsoft.Storage/storageAccounts@2022-09-01' existing = {
  name: storageAccountName
}

// Usa resource symbol reference para obter keys
var storageKey = storageAccountExisting.listKeys().keys[0].value
var storageConn = 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageKey};EndpointSuffix=${environment().suffixes.storage}'

// Cria o Function App em Linux, runtime Python
resource functionApp 'Microsoft.Web/sites@2022-03-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: functionPlan.id
    siteConfig: {
      // Runtime Python 3.9; ajuste se precisar outra versão suportada
      linuxFxVersion: 'PYTHON|3.9'
      appSettings: [
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'AzureWebJobsStorage'
          value: storageConn
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
      ]
    }
  }
  // Não precisa de dependsOn explícito em functionPlan, pois Bicep infere via functionPlan.id
}

// Outputs úteis
output functionAppResourceId string = functionApp.id
output functionAppDefaultHostname string = functionApp.properties.defaultHostName
output functionAppPrincipalId string = functionApp.identity.principalId
output usedStorageConnectionString string = storageConn
