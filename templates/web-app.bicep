@description('Nome do Web App a criar/atualizar')
param webAppName string

@description('Nome do App Service Plan existente')
param planName string

@description('Nome da imagem Docker no formato <registry>/<repo>:<tag>')
param imageName string

@description('URL do registry Docker. Se vazio, assume público Docker Hub.')
param containerRegistryUrl string = ''

@description('Username para o registry (se privado).')
param containerRegistryUsername string = ''

@secure()
@description('Password para o registry (se privado).')
param containerRegistryPassword string = ''

@description('Nome da Storage Account para app settings.')
param storageAccountName string

@description('Nome do container na Storage Account.')
param containerName string

@secure()
@description('SAS token para o container (opcional). Se vazio, não será adicionado como APP SETTING.')
param containerSasToken string = ''

@secure()
@description('URL completo do container com SAS (opcional). Será colocado em APP SETTING CONTAINER_ENDPOINT_SAS se não vazio.')
param containerEndpointSas string = ''

@description('URL completa da Function (com chave) para app setting FUNCTION_URL. Se vazio, não adiciona.')
param functionUrl string = ''

@description('URL completa da Function (com chave) para app setting GET_POSTS_FUNCTION_URL. Se vazio, não adiciona.')
param functionGetPostsUrl string = ''

@description('URL completa da Function (com chave) para app setting REPORT_FUNCTION_URL. Se vazio, não adiciona.')
param functionGenerateReport string = ''

@description('Nome da Cosmos DB Account existente')
param cosmosAccountName string

@description('Endpoint do Translator (opcional).')
param translatorEndpoint string = ''

@secure()
@description('Chave do Translator (opcional).')
param translatorKey string = ''

var usePrivateRegistry = containerRegistryUrl != ''
var addFunctionUrl = functionUrl != ''
var addContainerSas = containerSasToken != ''
var addContainerEndpoint = containerEndpointSas != ''
var addTranslator = translatorEndpoint != '' && translatorKey != ''

resource appServicePlan 'Microsoft.Web/serverfarms@2021-02-01' existing = {
  name: planName
}

resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2021-04-15' existing = {
  name: cosmosAccountName
}

var cosmosEndpoint = cosmosAccount.properties.documentEndpoint
var cosmosKeys = listKeys(cosmosAccount.id, '2021-04-15')
var cosmosKey = cosmosKeys.primaryMasterKey

var baseAppSettings = [
  {
    name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
    value: 'false'
  }
  {
    name: 'STORAGE_ACCOUNT_NAME'
    value: storageAccountName
  }
  {
    name: 'CONTAINER_NAME'
    value: containerName
  }
  {
    name: 'COSMOS_ENDPOINT'
    value: cosmosEndpoint
  }
  {
    name: 'COSMOS_KEY'
    value: cosmosKey
  }
]

var containerSasSettings = addContainerSas ? [
  {
    name: 'CONTAINER_SAS_TOKEN'
    value: containerSasToken
  }
] : []

var containerEndpointSettings = addContainerEndpoint ? [
  {
    name: 'CONTAINER_ENDPOINT_SAS'
    value: containerEndpointSas
  }
] : []

var privateRegistrySettings = usePrivateRegistry ? [
  {
    name: 'DOCKER_REGISTRY_SERVER_URL'
    value: containerRegistryUrl
  }
  {
    name: 'DOCKER_REGISTRY_SERVER_USERNAME'
    value: containerRegistryUsername
  }
  {
    name: 'DOCKER_REGISTRY_SERVER_PASSWORD'
    value: containerRegistryPassword
  }
] : []

var functionUrlSettings = addFunctionUrl ? [
  {
    name: 'FUNCTION_URL'
    value: functionUrl
  }
  {
    name: 'GET_POSTS_FUNCTION_URL'
    value: functionGetPostsUrl
  }
  {
    name: 'REPORT_FUNCTION_URL'
    value: functionGenerateReport
  }
] : []

// ✅ Novo bloco: Translator se fornecido
var translatorSettings = addTranslator ? [
  {
    name: 'TRANSLATOR_ENDPOINT'
    value: translatorEndpoint
  }
  {
    name: 'TRANSLATOR_KEY'
    value: translatorKey
  }
] : []

resource webApp 'Microsoft.Web/sites@2021-03-01' = {
  name: webAppName
  location: resourceGroup().location
  kind: 'app,linux'
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'DOCKER|${imageName}'
      alwaysOn: true
      cors: {
        allowedOrigins: [
          'https://portal.azure.com'
        ]
      }
      appSettings: concat(
        concat(
          concat(
            concat(
              concat(
                baseAppSettings,
                containerSasSettings
              ),
              containerEndpointSettings
            ),
            privateRegistrySettings
          ),
          functionUrlSettings
        ),
        translatorSettings
      )
      http20Enabled: true
    }
  }
}

output defaultHostName string = webApp.properties.defaultHostName
