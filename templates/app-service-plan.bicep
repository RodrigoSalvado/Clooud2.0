param planName string
param skuTier string
param skuName string
param capacity int
param isLinux bool = true
param location string = resourceGroup().location

resource plan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: planName
  location: location
  sku: {
    name: skuName
    tier: skuTier
    capacity: capacity
  }
  properties: {
    reserved: isLinux
  }
}

output appServicePlanId string = plan.id
