@description('Nome do Function App')
param functionAppName string

@description('Nome da Storage Account existente para AzureWebJobsStorage (GPv2).')
param storageAccountName string

@description('Localização para o Function App e plano. Por padrão, usa resourceGroup().location')
param location string = resourceGroup().location

@description('ResourceId de Application Insights existente. Se vazio e createAppInsights=true, será criado um novo Insights com o nome appInsightsName.')
param appInsightsResourceId string = ''

@description('Se appInsightsResourceId vazio e createAppInsights=true, nome para o novo Application Insights.')
param appInsightsName string = '${functionAppName}-ai'

@description('Se true e appInsightsResourceId vazio, cria um novo Application Insights.')
param createAppInsights bool = true

@secure()
@description('String de conexão do Storage para AzureWebJobsStorage. Se vazio, será obtida via listKeys da Storage Account existente.')
param storageConnectionString string = ''

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

// Referência à Storage Account existente, para obter chaves se necessário
resource storageAccountExisting 'Microsoft.Storage/storageAccounts@2022-09-01' existing = {
  name: storageAccountName
}

// Calcula a connection string do storage
// Se o parâmetro storageConnectionString for não vazio, usamos ele.
// Caso contrário usamos listKeys para pegar a primeira key.
var storageKey = empty(storageConnectionString) ? listKeys(storageAccountExisting.name, storageAccountExisting.apiVersion).keys[0].value : ''
var storageConn = empty(storageConnectionString)
  ? 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageKey};EndpointSuffix=${environment().suffixes.storage}'
  : storageConnectionString

// Criar Application Insights se necessário
resource appInsightsNew 'microsoft.insights/components@2020-02-02' = if (createAppInsights && empty(appInsightsResourceId)) {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

// Determina o resourceId e instrumentationKey
var aiId = !empty(appInsightsResourceId) ? appInsightsResourceId : (createAppInsights ? appInsightsNew.id : '')
// Se aiId vazio, instrumentationKeyVar fica vazio; caso contrário, usa reference para pegar InstrumentationKey.
var instrumentationKeyVar = empty(aiId) ? '' : reference(aiId, '2020-02-02').InstrumentationKey

// Cria o Function App
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
        // Se existe Application Insights, adiciona as configurações
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: instrumentationKeyVar
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          value: empty(instrumentationKeyVar) ? '' : 'InstrumentationKey=${instrumentationKeyVar}'
        }
      ]
    }
  }
  dependsOn: [
    functionPlan
    // Só incluir dependOn em appInsightsNew se estivermos criando novo Insights
    appInsightsNew
  ]
}

// Outputs
output functionAppResourceId string = functionApp.id
output functionAppDefaultHostname string = functionApp.properties.defaultHostName
output functionAppPrincipalId string = functionApp.identity.principalId
output usedStorageConnectionString string = storageConn
output appInsightsResourceId string = aiId
output instrumentationKey string = instrumentationKeyVar
