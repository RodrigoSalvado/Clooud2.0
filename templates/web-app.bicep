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

var usePrivateRegistry = containerRegistryUrl != ''
var addFunctionUrl = functionUrl != ''
var addContainerSas = containerSasToken != ''
var addContainerEndpoint = containerEndpointSas != ''

resource appServicePlan 'Microsoft.Web/serverfarms@2021-02-01' existing = {
  name: planName
}

// 1) Configurações básicas sempre incluídas
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
]

// 2) Se fornecido SAS token isolado, adiciona CONTAINER_SAS_TOKEN
var containerSasSettings array = addContainerSas ? [
  {
    name: 'CONTAINER_SAS_TOKEN'
    value: containerSasToken
  }
] : []

// 3) Se fornecido endpoint completo com SAS, adiciona CONTAINER_ENDPOINT_SAS
var containerEndpointSettings array = addContainerEndpoint ? [
  {
    name: 'CONTAINER_ENDPOINT_SAS'
    value: containerEndpointSas
  }
] : []

// 4) Configurações de registry privado, se aplicável
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

// 5) Configuração de FUNCTION_URL, se aplicável
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
      // Imagem de container Docker
      linuxFxVersion: 'DOCKER|${imageName}'
      alwaysOn: true

      // CORS fixo apenas para portal.azure.com
      cors: {
        allowedOrigins: [
          'https://portal.azure.com'
        ]
      }

      // Concatena todos os arrays de App Settings, incluindo apenas os não vazios
      appSettings: concat(
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
      )

      http20Enabled: true
    }
  }
}

output defaultHostName string = webApp.properties.defaultHostName
