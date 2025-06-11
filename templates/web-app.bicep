@description('Nome do Web App a criar')
param webAppName string

@description('Nome do App Service Plan existente')
param planName string

@description('Imagem Docker a usar, ex: "rodrig0salv/minha-app:latest"')
param imageName string

@description('SAS token para Storage se necessário (pode estar vazio)')
param containerSasToken string = ''

@description('Nome da Storage Account para usar na App Settings (se o teu código consome blobs via SAS)')
param storageAccountName string = ''

@description('Nome do container na Storage Account para usar (se aplicável)')
param containerName string = ''

@description('URL de um Container Registry privado (ex.: myregistry.azurecr.io), ou vazio')
param containerRegistryUrl string = ''

@description('Username do Container Registry, se privado')
param containerRegistryUsername string = ''

@secure()
@description('Password do Container Registry, se privado')
param containerRegistryPassword string = ''

@description('Indica se deves criar role assignment depois (false se fazes manualmente no workflow)')
param createRoleAssignment bool = false

// Obtém a referência ao App Service Plan existente
resource appServicePlan 'Microsoft.Web/serverfarms@2022-03-01' existing = {
  name: planName
}

// Cria o Web App Linux com Container
resource webApp 'Microsoft.Web/sites@2022-03-01' = {
  name: webAppName
  location: resourceGroup().location
  kind: 'app,linux,container'
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      // Define a runtime: imagem docker
      linuxFxVersion: 'DOCKER|${imageName}'
      // Se usares registro privado, configura credenciais
      {% if containerRegistryUrl != '' %}
      acrUseManagedIdentityCreds: false
      acrPullUserName: containerRegistryUsername
      acrPullPassword: containerRegistryPassword
      {% else %}
      // nada extra se imagem pública no Docker Hub
      {% endif %}
      // Outras definições, p.ex. alwaysOn, etc.
      alwaysOn: true
      // Se quiseres variáveis de ambiente:
      appSettings: [
        // Se houver SAS token e storageAccountName/containerName, podes definir uma setting
        // p.ex. STORAGE_SAS_URL = "https://<storageAccount>.blob.core.windows.net/<container>?<SAS>"
        // Só define se tiveres parâmetros não vazios:
        // Nota: fazer condicional em Bicep numa lista é verboso; uma estratégia é construir array
      ]
    }
  }
  identity: {
    type: 'SystemAssigned'
  }
}

// Exemplo de como construir appSettings condicionalmente:
var settings = [
  // Sempre podes definir outras settings fixas aqui
]

var storageSettingName = 'STORAGE_SAS_URL'
var storageSasUrl = (storageAccountName != '' && containerName != '' && containerSasToken != '')
  ? 'https://${storageAccountName}.blob.core.windows.net/${containerName}?${containerSasToken}'
  : ''

// Se storageSasUrl não for vazio, adiciona ao array de settings
var appSettingsCombined = (storageSasUrl != '')
  ? union(settings, [
      {
        name: storageSettingName
        value: storageSasUrl
      }
    ])
  : settings

// Agora, refaz o resource webApp mas usando appSettingsCombined
resource webAppWithSettings 'Microsoft.Web/sites@2022-03-01' = {
  name: webAppName
  location: resourceGroup().location
  kind: 'app,linux,container'
  properties: {
    serverFarmId: appServicePlan.id
    siteConfig: {
      linuxFxVersion: 'DOCKER|${imageName}'
      alwaysOn: true
      appSettings: [
        for setting in appSettingsCombined: {
          name: setting.name
          value: setting.value
        }
      ]
      {% if containerRegistryUrl != '' %}
      acrUseManagedIdentityCreds: false
      acrPullUserName: containerRegistryUsername
      acrPullPassword: containerRegistryPassword
      {% endif %}
    }
  }
  identity: {
    type: 'SystemAssigned'
  }
}

// NOTA: não tentar fazer role assignment aqui em Bicep, pois principalId não é conhecido no início.
// Se createRoleAssignment == true, aconselha-se a fazer via CLI ou script pós-deploy.
// Por exemplo, no workflow PowerShell/Bash: 
//   PRINCIPAL_ID=$(az webapp show ... --query identity.principalId -o tsv)
//   STORAGE_ID=$(az storage account show ... --query id -o tsv)
//   az role assignment create --assignee-object-id $PRINCIPAL_ID --role Contributor --scope $STORAGE_ID

// Outputs úteis:
output webAppDefaultHostName string = webApp.properties.defaultHostName
output principalId string = webApp.identity.principalId
