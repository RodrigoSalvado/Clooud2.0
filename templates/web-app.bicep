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
@description('SAS token para o container.')
param containerSasToken string

@description('URL completa da Function (com master key), para app setting FUNCTION_URL. Se vazio, não adiciona.')
param functionUrl string = ''

@description('Origens permitidas para CORS. Ex: ["https://meusite.com"]. Use ["*"] com cautela.')
param allowedCorsOrigins array = []

var usePrivateRegistry = containerRegistryUrl != ''
var addFunctionUrl = functionUrl != ''

resource appServicePlan 'Microsoft.Web/serverfarms@2021-02-01' existing = {
  name: planName
}

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
    name: 'CONTAINER_SAS_TOKEN'
    value: containerSasToken
  }
]

// Anotação de tipo “array” garante que [] vazio casa com o tipo
var privateRegistrySettings array = usePrivateRegistry ? [
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

var functionUrlSettings array = addFunctionUrl ? [
  {
    name: 'FUNCTION_URL'
    value: functionUrl
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
        allowedOrigins: allowedCorsOrigins
      }

      appSettings: baseAppSettings + privateRegistrySettings + functionUrlSettings

      http20Enabled: true
    }
  }
}

output defaultHostName string = webApp.properties.defaultHostName
