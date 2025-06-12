// parâmetros básicos
@description('Nome do Function App a criar/atualizar')
param functionAppName string

@description('Nome da Storage Account existente para AzureWebJobsStorage (GPv2). Ex: “mystorageaccount”')
param storageAccountName string

@description('Localização para o Function App e plano. Por padrão, usa resourceGroup().location')
param location string = resourceGroup().location

@description('Resource ID de um App Service Plan existente que queira usar. Se vazio, será criado um novo plano de Consumo Linux automaticamente.')
param existingPlanResourceId string = ''

// (Opcional) Se você quiser aceitar parâmetro de connection string em vez de pegar via listKeys:
//@secure()
//param storageConnectionString string = ''

// Referência à Storage Account existente, para obter a connection string se necessário:
resource storageAccountExisting 'Microsoft.Storage/storageAccounts@2022-09-01' existing = {
  name: storageAccountName
}

// (Opcional) obter connection string se você preferir ler a partir de listKeys. 
// Aqui assumimos que você deseja usar identity para acesso ou connection string passada externamente.
// Se quiser pegar via listKeys, descomente e adapte abaixo:
// var storageKey = listKeys(storageAccountExisting.name, storageAccountExisting.apiVersion).keys[0].value
// var storageConn = 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageKey};EndpointSuffix=${environment().suffixes.storage}'

//
// Criação condicional do App Service Plan, se existingPlanResourceId está vazio.
// Assumimos Consumo Linux (SKU Y1).
//
resource newFunctionPlan 'Microsoft.Web/serverfarms@2022-03-01' = if (empty(existingPlanResourceId)) {
  name: '${functionAppName}-plan'
  location: location
  kind: 'functionapp'
  sku: {
    name: 'Y1'
    tier: 'Dynamic'
  }
  properties: {
    reserved: true // indica Linux
  }
}

// Determina o resourceId efetivo do plano:
var planId = empty(existingPlanResourceId) ? newFunctionPlan.id : existingPlanResourceId

// Cria o Function App
resource functionApp 'Microsoft.Web/sites@2022-03-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: planId
    siteConfig: {
      // Exemplo de runtime Python 3.11; ajuste se precisar outra versão suportada
      linuxFxVersion: 'PYTHON|3.11'
      alwaysOn: true
      appSettings: [
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        {
          name: 'AzureWebJobsStorage'
          // Ajuste conforme sua estratégia: usar connection string ou identity-based. 
          // Aqui exemplificamos pegando via identity + configuração externa, mas você pode preferir connection string:
          // value: storageConn
          value: '' // Se usar identity-based ou outra abordagem, deixe vazio ou configure via Key Vault.
        }
        {
          name: 'WEBSITE_RUN_FROM_PACKAGE'
          value: '1'
        }
      ]
    }
  }
  // Se criamos novo plano, dependemos dele. Se usamos existingPlanResourceId, não adicionamos dependOn.
  dependsOn: empty(existingPlanResourceId) ? [
    newFunctionPlan
  ] : []
}

// Outputs úteis
output functionAppResourceId string = functionApp.id
output functionAppDefaultHostname string = functionApp.properties.defaultHostName
output functionAppPrincipalId string = functionApp.identity.principalId
