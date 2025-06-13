@description('Nome do Web App a criar/atualizar')
param webAppName string

@description('Nome do App Service Plan existente (deve já existir no mesmo resource group) ou que será referenciado')
param planName string

@description('Nome da imagem Docker, no formato <registry>/<repository>:<tag>, ex: "rodrig0salv/minha-app:latest"')
param imageName string

@description('URL do registry Docker (ex: https://index.docker.io ou URL do container registry). Se vazio, considera imagem pública no Docker Hub.')
param containerRegistryUrl string = ''

@description('Username para o registry. Se containerRegistryUrl vazio, pode ser deixado em branco.')
param containerRegistryUsername string = ''

@description('Password para o registry. Se containerRegistryUrl vazio, pode ser deixado em branco.')
param containerRegistryPassword string = ''

@description('Nome da Storage Account para uso pela aplicação (apenas para app settings).')
param storageAccountName string

@description('Nome do container dentro da Storage Account (apenas para app settings).')
param containerName string

@description('SAS token a usar no acesso ao container (apenas para app settings).')
param containerSasToken string

@description('URL da Function (SearchFunction) com a master key, para armazenar no app setting FUNCTION_URL. Se vazio, não será adicionado.')
param functionUrl string = ''

// Referência ao App Service Plan existente:
resource appServicePlan 'Microsoft.Web/serverfarms@2021-02-01' existing = {
  name: planName
}

// Web App resource
resource webApp 'Microsoft.Web/sites@2021-03-01' = {
  name: webAppName
  location: resourceGroup().location
  kind: 'app,linux'
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: {
      // Define a imagem de container Docker
      linuxFxVersion: 'DOCKER|' + imageName

      // Always On recomendado para container apps
      alwaysOn: true

      // Desabilita uso de storage compartilhado do App Service (pode ajustar conforme seu cenário; false evita montar storage)
      appSettings: concat(
        [
          // Se sua aplicação usa arquivos locais ou storage, ajuste WEBSITES_ENABLE_APP_SERVICE_STORAGE conforme necessário.
          // Aqui colocamos false para container sem storage compartilhado; altere para 'true' se precisar montar conteúdo via App Service Storage.
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
        ],
        // Se existe credencial de registry privado, adiciona as settings de Docker
        containerRegistryUrl != '' ? [
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
        ] : [],
        // Se functionUrl for fornecido, adiciona FUNCTION_URL
        functionUrl != '' ? [
          {
            name: 'FUNCTION_URL'
            value: functionUrl
          }
        ] : []
      )

      // Se precisar de outras configurações (ex: http20Enabled, logs, etc), você pode adicionar aqui.
      // Exemplo de habilitar HTTP/2:
      http20Enabled: true
    }
  }
}

// (Opcional) Se quiser garantir que existe uma configuração de host name binding ou custom domain, etc, inclua aqui.
// Por simplicidade, este template apenas cria/atualiza o Web App que referencia um App Service Plan existente e define container.

// Saída opcional: hostName para referência em outros módulos ou scripts
output defaultHostName string = webApp.properties.defaultHostName
