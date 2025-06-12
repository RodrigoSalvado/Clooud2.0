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

// Local do resource group
var location = resourceGroup().location

// 1) Se precisa criar AI, declaramos o recurso com condicional
resource ai 'microsoft.insights/components@2020-02-02' = if (createAppInsights) {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

// 2) Determina o instrumentation key efetivo:
//    - Se criamos AI, usamos ai.properties.InstrumentationKey.
//    - Senão, se o parâmetro for vazio, resulta em string vazia, caso contrário, usa o parâmetro.
var effectiveInstrumentationKey = createAppInsights 
  ? ai.properties.InstrumentationKey 
  : (empty(appInsightsInstrumentationKey) ? '' : appInsightsInstrumentationKey)

// 3) Construção das App Settings em partes:

// 3.1 Base de settings que sempre vão existir:
var baseSettings = [
  {
    name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
    value: 'false'
  }
]

// 3.2 Settings de Container Registry, apenas se preenchido:
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

// 3.3 Settings de Storage (opcional):
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

// 3.4 Settings de Application Insights, somente se tivermos effectiveInstrumentationKey não vazio:
var aiSettings = empty(effectiveInstrumentationKey) 
  ? [] 
  : [
      {
        name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
        value: effectiveInstrumentationKey
      },
      {
        name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
        // Usa string interpolation: 'InstrumentationKey=<valor>'
        value: 'InstrumentationKey=${effectiveInstrumentationKey}'
      }
    ]

// 3.5 Concatena todas as partes:
var allAppSettings = concat(baseSettings, registrySettings, storageSettings, aiSettings)


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
      // String interpolation para Linux container: "DOCKER|<imageName>"
      linuxFxVersion: 'DOCKER|${imageName}'
      alwaysOn: true
      appSettings: allAppSettings
      // Outras configurações opcionais podem ser adicionadas aqui
    }
  }
  // Dependência condicional em AI: se criamos AI, espera antes de criar WebApp
  dependsOn: createAppInsights ? [
    ai
  ] : []
}

// Outputs úteis:
output defaultHostName string = webApp.properties.defaultHostName
output principalId string = webApp.identity.principalId
