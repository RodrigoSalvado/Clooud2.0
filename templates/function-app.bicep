@description('Nome da Function App a ser criada ou atualizada')
param functionAppName string

@description('Nome do App Service Plan existente (Server Farm) a ser usado pela Function App')
param planName string = 'ASP-MiniProjetoCloud2.0'

@description('Nome da Storage Account existente para AzureWebJobsStorage e deployment storage')
param storageAccountName string = 'miniprojetostorage20'

@description('Nome da Cosmos DB Account existente')
param cosmosAccountName string = 'cosmosdbminiprojeto'

@description('Nome do Cosmos SQL Database existente')
param cosmosDatabaseName string = 'RedditApp'

@description('Nome do Cosmos SQL Container existente')
param cosmosContainerName string = 'posts'

@description('Reddit user (hardcoded)')
param redditUser string = 'Major-Noise-6411'

@secure()
@description('Reddit password (hardcoded)')
param redditPassword string = 'miniprojetocloud'

@secure()
@description('Secret custom (hardcoded)')
param secretValue string = 'DoywW0Lcc26rvDforDKkLOSQsUUwYA'

@secure()
@description('Client ID (hardcoded)')
param clientIdValue string = 'bzG6zHjC23GSenSIXe0M-Q'

@secure()
@description('SAS token ou URL do container com SAS (opcional). Se vazio, não será adicionado como APP SETTING.')
param containerEndpointSas string = ''

@description('Translator endpoint (deixe vazio se não for usar)')
param translatorEndpoint string = ''

@secure()
@description('Translator key (deixe vazio se não for usar)')
param translatorKey string = ''

var location = resourceGroup().location

// Monta o resourceId do App Service Plan existente no mesmo resource group:
// Ex: /subscriptions/{subId}/resourceGroups/{rgName}/providers/Microsoft.Web/serverfarms/{planName}
var planResourceId = resourceId('Microsoft.Web/serverfarms', planName)

// Referencia Storage Account existente
resource storageAccount 'Microsoft.Storage/storageAccounts@2022-09-01' existing = {
  name: storageAccountName
}
// Lista keys para montar connection string
var storageKeys = listKeys(storageAccount.id, '2022-09-01')
var primaryStorageKey = storageKeys.keys[0].value
var storageConnectionString = 'DefaultEndpointsProtocol=https;AccountName=${storageAccount.name};AccountKey=${primaryStorageKey};EndpointSuffix=core.windows.net'

// Referencia Cosmos DB Account existente
resource cosmosAccount 'Microsoft.DocumentDB/databaseAccounts@2021-04-15' existing = {
  name: cosmosAccountName
}
// Obter endpoint e chave primária do Cosmos DB
var cosmosEndpoint = cosmosAccount.properties.documentEndpoint
var cosmosKeys = listKeys(cosmosAccount.id, '2021-04-15')
var cosmosPrimaryKey = cosmosKeys.primaryMasterKey

// Criação / atualização da Function App
resource functionApp 'Microsoft.Web/sites@2024-04-01' = {
  name: functionAppName
  location: location
  kind: 'functionapp,linux'
  properties: {
    serverFarmId: planResourceId
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Python|3.10'
      // Adicionar CORS para permitir chamadas de https://portal.azure.com, se necessário
      cors: {
        allowedOrigins: [
          'https://portal.azure.com'
        ]
        supportCredentials: true
      }
      appSettings: [
        // Runtime
        {
          name: 'FUNCTIONS_WORKER_RUNTIME'
          value: 'python'
        }
        // Storage para AzureWebJobsStorage
        {
          name: 'AzureWebJobsStorage'
          value: storageConnectionString
        }
        // Configurações do Cosmos
        {
          name: 'COSMOS_ENDPOINT'
          value: cosmosEndpoint
        }
        {
          name: 'COSMOS_KEY'
          value: cosmosPrimaryKey
        }
        {
          name: 'COSMOS_DATABASE'
          value: cosmosDatabaseName
        }
        {
          name: 'COSMOS_CONTAINER'
          value: cosmosContainerName
        }
        // Storage para deployment ou uso custom
        {
          name: 'DEPLOYMENT_STORAGE_CONNECTION_STRING'
          value: storageConnectionString
        }
        // Credenciais do Reddit
        {
          name: 'REDDIT_USER'
          value: redditUser
        }
        {
          name: 'REDDIT_PASSWORD'
          value: redditPassword
        }
        // Secret custom
        {
          name: 'SECRET'
          value: secretValue
        }
        // CLIENT_ID
        {
          name: 'CLIENT_ID'
          value: clientIdValue
        }
        // Translator (pode ficar vazio)
        {
          name: 'TRANSLATOR_ENDPOINT'
          value: translatorEndpoint
        }
        {
          name: 'TRANSLATOR_KEY'
          value: translatorKey
        }
        // SAS do container (se fornecido)
        // O nome do setting aqui deve bater com o que sua aplicação espera, por ex. CONTAINER_ENDPOINT_SAS
        // e o valor é o parâmetro containerEndpointSas.
        // Se containerEndpointSas for vazio, ainda assim será definido, mas você pode no código
        // ignorar valor vazio se desejar.
        {
          name: 'CONTAINER_ENDPOINT_SAS'
          value: containerEndpointSas
        }
      ]
    }
    // Se não quiser Managed Identity, não declara identity.
    // identity: {
    //   type: 'SystemAssigned'
    // }
  }
}

// Saída do hostname da Function App
output functionAppDefaultHostName string = functionApp.properties.defaultHostName
