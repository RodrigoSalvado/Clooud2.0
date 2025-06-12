@description('Nome do Web App a criar/atualizar')
param webAppName string

@description('Nome do App Service Plan existente (ou criado anteriormente) a usar')
param planName string

@description('Nome da imagem de container no formato <registry>/<repo>:<tag>')
param imageName string

@description('URL do Container Registry (opcional). Se não usar auth, deixe vazio.')
param containerRegistryUrl string = ''

@description('Username do Container Registry (opcional)')
param containerRegistryUsername string = ''

@secure()
@description('Password/secret do Container Registry (opcional)')
param containerRegistryPassword string = ''

@description('Nome da Storage Account (opcional)')
param storageAccountName string = ''

@description('Nome do container na Storage Account (opcional)')
param containerName string = ''

@description('SAS token para o container (opcional). Pode estar vazio.')
param containerSasToken string = ''

// Local do resource group
var location = resourceGroup().location

// 1) Construção das App Settings em partes:

// 1.1 Base de settings que sempre vão existir:
var baseSettings = [
  {
    name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
    value: 'false'
  }
]

// 1.2 Settings de Container Registry, apenas se preenchido:
var registrySettings = concat(
  [],
  containerRegistryUrl == '' ? [] : [
    {
      name: 'DOCKER_REGISTRY_SERVER_URL'
      value: containerRegistryUrl
    }
  ],
  containerRegistryUsername == '' ? [] : [
    {
      name: 'DOCKER_REGISTRY_SERVER_USERNAME'
      value: containerRegistryUsername
    }
  ],
  containerRegistryPassword == '' ? [] : [
    {
      name: 'DOCKER_REGISTRY_SERVER_PASSWORD'
      value: containerRegistryPassword
    }
  ]
)

// 1.3 Settings de Storage (opcional):
var storageSettings = concat(
  [],
  storageAccountName == '' ? [] : [
    {
      name: 'STORAGE_ACCOUNT_NAME'
      value: storageAccountName
    }
  ],
  containerName == '' ? [] : [
    {
      name: 'CONTAINER_NAME'
      value: containerName
    }
  ],
  containerSasToken == '' ? [] : [
    {
      name: 'CONTAINER_SAS_TOKEN'
      value: containerSasToken
    }
  ]
)

// 1.4 Concatena todas as partes:
var allAppSettings = concat(baseSettings, registrySettings, storageSettings)

// *** Recurso Web App ***
resource webApp 'Microsoft.Web/sites@2021-02-01' = {
  name: webAppName
  location: location
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: resourceId('Microsoft.Web/serverfarms', planName)
    siteConfig: {
      // String interpolation para Linux container:
      linuxFxVersion: 'DOCKER|${imageName}'
      alwaysOn: true
      appSettings: allAppSettings
      // Outras configurações opcionais podem ser adicionadas aqui
    }
  }
}

// Outputs úteis:
output defaultHostName string = webApp.properties.defaultHostName
output principalId string = webApp.identity.principalId
