@description('Nome do Web App (Linux Container).')
param webAppName string

@description('App Service Plan (resourceId ou apenas nome em mesmos RG e subscription). Aqui usamos o nome e assumimos que o plano já existe ou será criado separadamente.')
param planName string

@description('Imagem de container (ex: "rodrig0salv/minha-app:latest").')
param imageName string

@description('URL do registro de container, se for necessário (ex: myregistry.azurecr.io). Se não usar ACR ou login público, deixe vazio.')
param containerRegistryUrl string = ''

@secure()
@description('Usuário do registro de container, se necessário. Se não usar ACR ou login público, deixe vazio.')
param containerRegistryUsername string = ''

@secure()
@description('Senha ou senha de acesso ao registro de container, se necessário. Se não usar ACR ou login público, deixe vazio.')
param containerRegistryPassword string = ''

@description('Nome da Storage Account existente, para gerar SAS ou atribuir roles, se sua aplicação usar. Se não usar, deixe vazio.')
param storageAccountName string = ''

@description('Nome do container dentro da Storage Account (para SAS ou configuração de app setting). Se não usar, deixe vazio.')
param containerName string = ''

@description('SAS token para acesso ao Storage (string sem o “?” no início). Se você já gerou externamente, passe aqui; caso contrário, deixe vazio e trate no pipeline se desejar.')
param containerSasToken string = ''

@description('Se true, cria um Application Insights neste RG. Se false, espera que você passe appInsightsResourceId para ligar a um Insights existente. Se false e appInsightsResourceId vazio, não adiciona configurações de Insights.')
param createAppInsights bool = false

@description('Nome para o novo Application Insights, se createAppInsights=true.')
param appInsightsName string = '${webAppName}-ai'

@description('Resource ID de um Application Insights já existente, se quiser ligar o Web App a um Insights existente. Se não quiser usar Insights, deixe vazio.')
param appInsightsResourceId string = ''

@description('Localização para criar o Application Insights, se createAppInsights=true. Por padrão, usa resourceGroup().location.')
param location string = resourceGroup().location

@description('Indica se o Web App deve ter identidade atribuída (Managed Identity). Se true, cria SystemAssigned identity e habilita para uso em atribuições de role.')
param enableSystemIdentity bool = true

// =======================
// Recursos opcionais
// =======================

// Se createAppInsights=true e não foi passado appInsightsResourceId, criamos novo Insights
resource appInsightsNew 'microsoft.insights/components@2020-02-02' = if (createAppInsights && empty(appInsightsResourceId)) {
  name: appInsightsName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

// Determina o resourceId do Insights a usar
var aiResourceIdUsed = !empty(appInsightsResourceId)
  ? appInsightsResourceId
  : (createAppInsights ? appInsightsNew.id : '')

// Obtém instrumentation key se existir AI
var instrumentationKeyVar = empty(aiResourceIdUsed)
  ? ''
  : reference(aiResourceIdUsed, '2020-02-02').InstrumentationKey

// =======================
// Recurso Web App
// =======================
resource webApp 'Microsoft.Web/sites@2022-03-01' = {
  name: webAppName
  location: location
  kind: 'app,linux,container'
  identity: enableSystemIdentity ? {
    type: 'SystemAssigned'
  } : null
  properties: {
    serverFarmId: resourceId('Microsoft.Web/serverfarms', planName)
    siteConfig: {
      // Configurações básicas de container
      linuxFxVersion: 'DOCKER|' + imageName
      // Se registro privado, define credenciais:
      imageRegistryCredentials: empty(containerRegistryUrl) ? [] : [
        {
          serverUrl: containerRegistryUrl
          username: containerRegistryUsername
          password: containerRegistryPassword
        }
      ]
      // App Settings:
      appSettings: [
        {
          name: 'WEBSITES_ENABLE_APP_SERVICE_STORAGE'
          value: 'false'
        }
        // Configurar Storage SAS se fornecido
        {
          name: 'STORAGE_ACCOUNT_NAME'
          value: empty(storageAccountName) ? '' : storageAccountName
        }
        {
          name: 'STORAGE_CONTAINER_NAME'
          value: empty(containerName) ? '' : containerName
        }
        {
          name: 'STORAGE_SAS_TOKEN'
          value: empty(containerSasToken) ? '' : containerSasToken
        }
        // Application Insights
        {
          name: 'APPINSIGHTS_INSTRUMENTATIONKEY'
          value: instrumentationKeyVar
        }
        {
          name: 'APPLICATIONINSIGHTS_CONNECTION_STRING'
          // A connection string pode ser "InstrumentationKey=xxxx"; se não existir, vazio
          value: empty(instrumentationKeyVar) ? '' : 'InstrumentationKey=' + instrumentationKeyVar
        }
      ]
    }
  }
  dependsOn: [
    // Se criamos novo Insights, garantimos que existirá antes do Web App
    appInsightsNew
  ]
}

// =======================
// Outputs
// =======================
output webAppResourceId string = webApp.id
output webAppDefaultHostname string = webApp.properties.defaultHostName
output webAppPrincipalId string = webApp.identity.principalId
output appInsightsUsed string = aiResourceIdUsed
output instrumentationKey string = instrumentationKeyVar
