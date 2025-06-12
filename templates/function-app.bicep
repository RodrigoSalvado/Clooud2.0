@description('Nome do Function App a criar/atualizar')
param functionAppName string

@description('Nome da Storage Account existente para AzureWebJobsStorage (GPv2).')
param storageAccountName string

@description('Localização para o Function App e plano. Por padrão, usa resourceGroup().location')
param location string = resourceGroup().location

@secure()
@description('String de conexão do Storage para AzureWebJobsStorage. Se vazio, será obtida via listKeys da Storage Account existente.')
param storageConnectionString string = ''

// 1) Plano de Consumo para Function App (Linux Consumption)
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

// 2) Referência à Storage Account existente, para obter chaves se necessário
resource storageAccountExisting 'Microsoft.Storage/storageAccounts@2022-09-01' existing = {
  name: storageAccountName
}

// 3) Calcula a connection string do storage:
//    - Se o parâmetro storageConnectionString for não vazio, usa ele.
//    - Caso contrário usa listKeys para pegar a primeira key.
var storageKey = empty(storageConnectionString) 
  ? listKeys(storageAccountExisting.name, storageAccountExisting.apiVersion).keys[0].value 
  : ''
var storageConn = empty(storageConnectionString)
  ? 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageKey};EndpointSuffix=${environment().suffixes.storage}'
  : storageConnectionString

// 4) Cria o Function App sem Application Insights
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
      // Runtime Python; ajuste a versão conforme necessidade (3.9, 3.10, etc.)
      linuxFxVersion: 'PYTHON|3.9'
      appSettings: [
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        },
        {
          name: 'AzureWebJobsStorage'
          value: storageConn
        },
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
        // Se precisar de outras configurações, acrescente mais itens aqui, sempre separando com vírgula
      ]
    }
  }
  dependsOn: [
    functionPlan
    // não há dependência de Insights aqui
  ]
}

// Outputs úteis
output functionAppResourceId string = functionApp.id
output functionAppDefaultHostname string = functionApp.properties.defaultHostName
output functionAppPrincipalId string = functionApp.identity.principalId
output usedStorageConnectionString string = storageConn
