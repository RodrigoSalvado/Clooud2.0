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
@description('SAS token para o container (opcional, caso queira usar em separado).')
param containerSasToken string = ''

@description('URL completo do container com SAS (opcional). Será colocado em APP SETTING CONTAINER_ENDPOINT_SAS.')
param containerEndpointSas string = ''

@description('URL completa da Function (com chave), para app setting FUNCTION_URL. Se vazio, não adiciona.')
param functionUrl string = ''

var usePrivateRegistry = containerRegistryUrl != ''
var addFunctionUrl = functionUrl != ''
var addContainerEndpoint = containerEndpointSas != ''

resource appServicePlan 'Microsoft.Web/serverfarms@2021-02-01' existing = {
  name: planName
}

// 1) baseAppSettings como array explicitamente
var baseAppSettings array = [
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
  // Mantemos containerSasToken se quiser usar em código ou referência separada
  {
    name: 'CONTAINER_SAS_TOKEN'
    value: containerSasToken
  }
]

// 2) settings opcionais para registry privado
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

// 3) settings opcionais para FUNCTION_URL
var functionUrlSettings array = addFunctionUrl ? [
  {
    name: 'FUNCTION_URL'
    value: functionUrl
  }
] : []

// 4) settings opcionais para CONTAINER_ENDPOINT_SAS
var containerEndpointSettings array = addContainerEndpoint ? [
  {
    name: 'CONTAINER_ENDPOINT_SAS'
    value: containerEndpointSas
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
      // Container image
      linuxFxVersion: 'DOCKER|${imageName}'
      alwaysOn: true

      // CORS fixo apenas para portal.azure.com
      cors: {
        allowedOrigins: [
          'https://portal.azure.com'
        ]
      }

      // Concatena todos os arrays de App Settings
      appSettings: concat(
        concat(
          concat(
            baseAppSettings,
            privateRegistrySettings
          ),
          functionUrlSettings
        ),
        containerEndpointSettings
      )

      http20Enabled: true
    }
  }
}

output defaultHostName string = webApp.properties.defaultHostName
