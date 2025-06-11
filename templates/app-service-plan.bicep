targetScope = 'resourceGroup'

// Parâmetros
@minLength(1)
@maxLength(40)
@description('Nome do App Service Plan. Por defeito "ASP-MiniProjetoCloud2.0".')
param planName string = 'ASP-MiniProjetoCloud2.0'

@description('Localização. Por defeito, usa a localização do Resource Group.')
param location string = resourceGroup().location

@allowed([
  'Free'
  'Shared'
  'Basic'
  'Standard'
  'PremiumV2'
  'PremiumV3'
  'ElasticPremium'
  'Isolated'
])
@description('Tier do SKU do App Service Plan. Por defeito "Basic" para usar B2.')
param skuTier string = 'Basic'

@description('Nome do SKU dentro do Tier. Para B2, usa "B2".')
param skuName string = 'B2'

@minValue(1)
@description('Número de instâncias (capacity). Por defeito 1.')
param capacity int = 1

@description('Se true, cria App Service Plan para Linux. Aqui true para Linux.')
param isLinux bool = true

// Recurso: App Service Plan
resource appServicePlan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: planName
  location: location
  sku: {
    tier: skuTier
    name: skuName
    capacity: capacity
  }
  kind: isLinux ? 'linux' : 'app'
  properties: {
    reserved: isLinux
  }
}

// Outputs
output appServicePlanId string = appServicePlan.id
output appServicePlanName string = appServicePlan.name
output appServicePlanSku object = {
  tier: appServicePlan.sku.tier
  name: appServicePlan.sku.name
  capacity: appServicePlan.sku.capacity
}
