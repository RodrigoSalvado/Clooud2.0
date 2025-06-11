targetScope = 'resourceGroup'

@minLength(1)
@maxLength(40)
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
param skuTier string = 'Basic'

@description('Nome do SKU dentro do Tier. Para B2, usa "B2".')
param skuName string = 'B2'

@minValue(1)
param capacity int = 1

@description('Se true, cria Plano Linux.')
param isLinux bool = true

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

output appServicePlanId string = appServicePlan.id
output appServicePlanName string = appServicePlan.name
