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

// Referência à Storage Account existente, para obter chaves
resource storageAccountExisting 'Microsoft.Storage/storageAccounts@2022-09-01' existing = {
  name: storageAccountName
}

// Obtenção da chave e connection string do storage
// Usando método simbólico listKeys para melhor dependência (se a versão suportar):
// storageAccountExisting.listKeys().keys[0].value
// Caso sua versão Bicep/Azure não suporte listKeys() diretamente como método, mantenha listKeys(resourceName, apiVersion).
var storageKey = storageAccountExisting.listKeys().keys[0].value
var storageConn = 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageKey};EndpointSuffix=${environment().suffixes.storage}'

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
      linuxFxVersion: 'PYTHON|3.11'
      appSettings: [
        // Cada objeto no array deve estar separado por vírgula, sem vírgulas extras dentro do objeto:
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
        // Se quiser adicionar mais settings, faça:
        // ,{
        //   name: 'OUTRA_SETTING'
        //   value: 'valor'
        // }
      ]
    }
  }
  // Não precisa de dependsOn explícito para functionPlan, a referência functionPlan.id já cuida disso.
}

// Outputs úteis
output functionAppResourceId string = functionApp.id
output functionAppDefaultHostname string = functionApp.properties.defaultHostName
output functionAppPrincipalId string = functionApp.identity.principalId
