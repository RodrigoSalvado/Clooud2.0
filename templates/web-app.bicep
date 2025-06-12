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

@description('Se true, cria um Application Insights novo com nome appInsightsName. Se false, usa AI existente via instrumentation key em appInsightsInstrumentationKey.')
param createAppInsights bool = false

@description('Nome a usar para Application Insights, se createAppInsights for true. Caso falso, pode deixar vazio.')
param appInsightsName string = ''

@secure()
@description('Instrumentation Key de um Application Insights existente, se createAppInsights for false. Caso createAppInsights=true, pode deixar vazio.')
param appInsightsInstrumentationKey string = ''

var location = resourceGroup().location

resource ai 'microsoft.insights/components@2020-02-02' = if (createAppInsights) {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

var effectiveInstrumentationKey = createAppInsights 
  ? ai.properties.InstrumentationKey 
  : (empty(appInsightsInstrumentationKey) ? '' : appInsightsInstrumentationKey)

var baseSettings = [
  {
    name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
    value: 'false'
  }
]

var registrySettings = concat(
  [],
  empty(containerRegistryUrl) ? [] : [
    {
      name: 'DOCKER_REGISTRY_SERVER_URL'
      value: containerRegistryUrl
    }
  ],
  empty(containerRegistryUsername) ? [] : [
    {
      name: 'DOCKER_REGISTRY_SERVER_USERNAME'
      value: containerRegistryUsername
    }
  ],
  empty(containerRegistryPassword) ? [] : [
    {
      name: 'DOCKER_REGISTRY_SERVER_PASSWORD'
      value: containerRegistryPassword
    }
  ]
)

var storageSettings = concat(
  [],
  empty(storageAccountName) ? [] : [
    {
      name: 'STORAGE_ACCOUNT_NAME'
      value: storageAccountName
    }
  ],
  empty(containerName) ? [] : [
    {
      name: 'CONTAINER_NAME'
      value: containerName
    }
  ],
  empty(containerSasToken) ? [] : [
    {
      name: 'CONTAINER_SAS_TOKEN'
      value: containerSasToken
    }
  ]
)

var aiSettings = empty(effectiveInstrumentationKey) 
  ? [] 
  : [
      {
        name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
        value: effectiveInstrumentationKey
      },
      {
        name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
        value: 'InstrumentationKey=${effectiveInstrumentationKey}'
      }
    ]

var allAppSettings = concat(baseSettings, registrySettings, storageSettings, aiSettings)

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
      linuxFxVersion: 'DOCKER|${imageName}'
      alwaysOn: true
      appSettings: allAppSettings
    }
  }
  dependsOn: createAppInsights ? [ ai ] : []
}

output defaultHostName string = webApp.properties.defaultHostName
output principalId string = webApp.identity.principalId
