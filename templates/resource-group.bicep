targetScope = 'subscription'

// Parâmetros
@minLength(1)
param rgName string = 'MiniProjetoCloud2.0'

// Define default para a localização, mas permite override via parâmetro
param location string = 'westeurope'

// Criação do Resource Group no escopo de subscrição
resource rg 'Microsoft.Resources/resourceGroups@2021-04-01' = {
  name: rgName
  location: location
}