@description('Nome do App Service Plan')
param planName string

@description('Localização (default resourceGroup().location)')
param location string = resourceGroup().location

@description('Tier do SKU, ex: Basic, Standard, Premium')
param skuTier string

@description('Nome do SKU, ex: B1, B2, S1, P1v2, etc.')
param skuName string

@description('Capacidade (instâncias)')
@minValue(1)
param capacity int = 1

@description('É Linux? true para Linux, false para Windows')
param isLinux bool = true

resource plan 'Microsoft.Web/serverfarms@2022-03-01' = {
  name: planName
  location: location
  sku: {
    name: skuName
    tier: skuTier
    capacity: capacity
  }
  properties: {
    reserved: isLinux  // reservada = true para Linux
    // Se Windows: reserved=false
  }
}
