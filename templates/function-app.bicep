@description('Nome do Function App a criar/atualizar')
param functionAppName string

@description('Resource ID do App Service Plan existente (Server Farm). Exemplo: /subscriptions/.../resourceGroups/.../providers/Microsoft.Web/serverfarms/ASP-XYZ')
param serverFarmId string

@description('Nome da Storage Account existente para AzureWebJobsStorage (GPv2).')
param storageAccountName string

@description('Connection string para AzureWebJobsStorage (opcional). Se vazio, será obtido via listKeys da Storage Account existente.')
param storageConnectionString string = ''

@description('URL do blob container ou do pacote para deployment (opcional). Exemplo: "https://<account>.blob.core.windows.net/app-package-<nome>?<sasToken>". Se vazio, não configura deployment automático.')
param packageContainerUrl string = ''

var location = resourceGroup().location

// Referência à Storage Account existente, para obter chaves se necessário
resource storageAccountExisting 'Microsoft.Storage/storageAccounts@2022-09-01' existing = {
  name: storageAccountName
}

// Calcula connection string do storage:
// - se storageConnectionString for informado (não vazio), usa ele diretamente;
// - caso contrário, obtém a primeira key via listKeys e monta DefaultEndpointsProtocol.
var storageKey = empty(storageConnectionString) 
  ? listKeys(storageAccountExisting.id, storageAccountExisting.apiVersion).keys[0].value 
  : ''
var finalStorageConn = empty(storageConnectionString) 
  ? 'DefaultEndpointsProtocol=https;AccountName=${storageAccountName};AccountKey=${storageKey};EndpointSuffix=${environment().suffixes.storage}' 
  : storageConnectionString

// Bloco runtime e escala
var runtimeBlock = {
  name: 'python'
  version: '3.11'
}
var scaleBlock = {
  maximumInstanceCount: 100
  instanceMemoryMB: 1536
}

// Monta functionAppConfig condicionalmente, com ou sem deployment via blob container
var functionAppConfig = empty(packageContainerUrl) ? {
  runtime: runtimeBlock
  scaleAndConcurrency: scaleBlock
} : {
  runtime: runtimeBlock
  deployment: {
    storage: {
      type: 'blobcontainer'
      value: packageContainerUrl
      authentication: {
        type: 'storageaccountconnectionstring'
        // Nome da app setting que conterá a connection string
        storageAccountConnectionStringName: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
      }
    }
  }
  scaleAndConcurrency: scaleBlock
}

// Monta appSettings: obrigatórios + opcionais para deployment
var baseSettings = [
  {
    name: 'FUNCTIONS_WORKER_RUNTIME'
    value: 'python'
  }
  {
    name: 'AzureWebJobsStorage'
    value: finalStorageConn
  }
]

// Se quisermos usar Run From Package via blob URL, muitas vezes se define:
//   WEBSITE_RUN_FROM_PACKAGE = '<url-do-zip-ou-sas-do-blob>'
// Porém, quando usamos functionAppConfig.deployment.storage do tipo 'blobcontainer', 
// o próprio serviço pode usar a setting DEPLOYMENT_STORAGE_CONNECTION_STRING.
// Caso queira setar WEBSITE_RUN_FROM_PACKAGE para URL direta, altere abaixo conforme necessidade.
var packageSettings = empty(packageContainerUrl) ? [] : [
  // Define a connection string para DEPLOYMENT_STORAGE_CONNECTION_STRING (usado por functionAppConfig.deployment)
  {
    name: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
    value: finalStorageConn
  }
  // Se preferir usar Run From Package direto com URL do pacote, acrescente algo como:
  // {
  //   name: 'WEBSITE_RUN_FROM_PACKAGE'
  //   value: packageContainerUrl
  // }
]

// Concatena todas
var allAppSettings = concat(baseSettings, packageSettings)

resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: serverFarmId
    enabled: true
    httpsOnly: true
    // Configurações de Function App: runtime e, se informado, deployment
    functionAppConfig: functionAppConfig
    siteConfig: {
      // appSettings com AzureWebJobsStorage, FUNCTIONS_WORKER_RUNTIME, DEPLOYMENT_STORAGE_CONNECTION_STRING etc.
      appSettings: allAppSettings
      // Outros ajustes opcionais:
      // alwaysOn: true  // em Consumo, alwaysOn não é suportado; deixe false ou omitido.
      // linuxFxVersion geralmente não é usado para runtime Python no modelo Function: 
      // para Linux Consumption, o runtimeBlock em functionAppConfig é suficiente.
    }
  }
  dependsOn: [
    // garante que storageAccountExisting exista antes de obter listKeys
    storageAccountExisting
  ]
}

// Outputs úteis
output functionAppResourceId string = functionApp.id
output defaultHostName string = functionApp.properties.defaultHostName
output principalId string = functionApp.identity.principalId
