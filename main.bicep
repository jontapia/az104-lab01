// =============================================================================
// jontapia-az104-lab — main.bicep
// Author: Jonathan Tapia (github.com/jontapia)
//
// Deploys a small, security-minded Azure environment that mirrors what a
// Tier 1 / Tier 2 help desk supports day to day:
//   - Segmented VNet + NSG (RDP locked to one admin IP, explicit deny-all)
//   - Windows Server 2022 VM with daily auto-shutdown (cost control)
//   - Least-privilege RBAC for a help desk Entra ID group
//   - Storage account hardened to TLS 1.2 / HTTPS only / no public blobs
//   - Recovery Services vault + daily backup policy protecting the VM
//   - Azure Monitor: Log Analytics, CPU alert, NSG-change alert, email action group
//
// Entra ID user/group are created by deploy.sh (Graph objects, not ARM resources)
// and passed in as helpdeskGroupObjectId.
// =============================================================================

targetScope = 'resourceGroup'

@description('Azure region for all regional resources.')
param location string = resourceGroup().location

@description('Owner tag applied to every resource.')
param owner string = 'jontapia'

@description('Local administrator username for the VM.')
param adminUsername string = 'jontapia'

@secure()
@minLength(12)
@description('Local administrator password for the VM.')
param adminPassword string

@description('Single public IP in CIDR form allowed to RDP in, e.g. 203.0.113.10/32.')
param allowedRdpSource string

@description('Object ID of the Entra ID help desk group granted VM Contributor on this resource group.')
param helpdeskGroupObjectId string

@description('Email address that receives Azure Monitor alerts.')
param alertEmail string

@description('VM size. B2s = 2 vCPU / 4 GiB, fits free-trial vCPU quotas.')
param vmSize string = 'Standard_B2s'

@description('Daily auto-shutdown time (HHmm, 24h) in Eastern Time.')
param autoShutdownTime string = '1900'

// -----------------------------------------------------------------------------
// Naming + tags
// -----------------------------------------------------------------------------
var prefix = 'jt-az104'
var vmName = 'jt-az104-vm01' // 13 chars, under the 15-char Windows hostname limit
var storageName = 'stjontapia${uniqueString(resourceGroup().id)}' // 23 chars, globally unique
var tags = {
  owner: owner
  project: 'az104-lab'
  environment: 'lab'
  managedBy: 'bicep'
}

// Built-in role: Virtual Machine Contributor
// Manage VMs (start/stop/restart/resize) but NOT the VNet, NSG or storage they use.
var vmContributorRoleId = '9980e02c-c2be-4d73-94e8-173b1dc7cf3c'

// -----------------------------------------------------------------------------
// Monitoring foundation
// -----------------------------------------------------------------------------
resource law 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: '${prefix}-law'
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: '${prefix}-ag-helpdesk'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'jt-helpdesk'
    enabled: true
    emailReceivers: [
      {
        name: 'Owner-Email'
        emailAddress: alertEmail
        useCommonAlertSchema: true
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Network
// -----------------------------------------------------------------------------
resource nsg 'Microsoft.Network/networkSecurityGroups@2023-11-01' = {
  name: '${prefix}-nsg-servers'
  location: location
  tags: tags
  properties: {
    securityRules: [
      {
        name: 'Allow-RDP-From-Admin-IP'
        properties: {
          description: 'RDP only from the lab owner\'s public IP.'
          priority: 100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: allowedRdpSource
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '3389'
        }
      }
      {
        name: 'Deny-All-Other-Inbound'
        properties: {
          description: 'Explicit deny so intent is visible in effective security rules.'
          priority: 4000
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nsgDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: nsg
  properties: {
    workspaceId: law.id
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2023-11-01' = {
  name: '${prefix}-vnet'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        '10.20.0.0/16'
      ]
    }
    subnets: [
      {
        name: 'snet-servers'
        properties: {
          addressPrefix: '10.20.1.0/24'
          networkSecurityGroup: {
            id: nsg.id
          }
        }
      }
    ]
  }
}

resource pip 'Microsoft.Network/publicIPAddresses@2023-11-01' = {
  name: '${vmName}-pip'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2023-11-01' = {
  name: '${vmName}-nic'
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: vnet.properties.subnets[0].id
          }
          publicIPAddress: {
            id: pip.id
          }
        }
      }
    ]
  }
}

// -----------------------------------------------------------------------------
// Compute
// -----------------------------------------------------------------------------
resource vm 'Microsoft.Compute/virtualMachines@2024-03-01' = {
  name: vmName
  location: location
  tags: tags
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    osProfile: {
      computerName: vmName
      adminUsername: adminUsername
      adminPassword: adminPassword
      windowsConfiguration: {
        provisionVMAgent: true
        enableAutomaticUpdates: true
        patchSettings: {
          patchMode: 'AutomaticByOS'
        }
      }
    }
    storageProfile: {
      imageReference: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2022-datacenter-g2'
        version: 'latest'
      }
      osDisk: {
        name: '${vmName}-osdisk'
        createOption: 'FromImage'
        deleteOption: 'Delete'
        managedDisk: {
          storageAccountType: 'StandardSSD_LRS'
        }
      }
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nic.id
          properties: {
            deleteOption: 'Delete'
          }
        }
      ]
    }
    diagnosticsProfile: {
      bootDiagnostics: {
        enabled: true
      }
    }
  }
}

resource autoShutdown 'Microsoft.DevTestLab/schedules@2018-09-15' = {
  name: 'shutdown-computevm-${vmName}'
  location: location
  tags: tags
  properties: {
    status: 'Enabled'
    taskType: 'ComputeVmShutdownTask'
    dailyRecurrence: {
      time: autoShutdownTime
    }
    timeZoneId: 'Eastern Standard Time'
    targetResourceId: vm.id
    notificationSettings: {
      status: 'Disabled'
    }
  }
}

// -----------------------------------------------------------------------------
// Identity / RBAC — least privilege for the help desk group
// -----------------------------------------------------------------------------
resource helpdeskVmContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, helpdeskGroupObjectId, vmContributorRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', vmContributorRoleId)
    principalId: helpdeskGroupObjectId
    principalType: 'Group'
    description: 'Tier 1 help desk: start/stop/restart lab VMs; no network or storage changes.'
  }
}

// -----------------------------------------------------------------------------
// Storage — hardened defaults
// -----------------------------------------------------------------------------
resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: tags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    accessTier: 'Hot'
    minimumTlsVersion: 'TLS1_2'
    supportsHttpsTrafficOnly: true
    allowBlobPublicAccess: false
  }
}

resource blobService 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: storage
  name: 'default'
  properties: {
    deleteRetentionPolicy: {
      enabled: true
      days: 7
    }
  }
}

resource scriptsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobService
  name: 'helpdesk-scripts'
  properties: {
    publicAccess: 'None'
  }
}

// -----------------------------------------------------------------------------
// Backup
// -----------------------------------------------------------------------------
resource vault 'Microsoft.RecoveryServices/vaults@2024-04-01' = {
  name: '${prefix}-rsv'
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    // Set redundancy on the vault itself (the old backupstorageconfig API is rejected now).
    redundancySettings: {
      standardTierStorageRedundancy: 'LocallyRedundant'
      crossRegionRestore: 'Disabled'
    }
    securitySettings: {
      // LAB ONLY: soft delete off so teardown.sh can delete the vault same day.
      // In production this stays Enabled (ransomware / accidental-delete protection).
      softDeleteSettings: {
        softDeleteState: 'Disabled'
        softDeleteRetentionPeriodInDays: 14
      }
    }
  }
}

resource vaultDiag 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'send-to-law'
  scope: vault
  properties: {
    workspaceId: law.id
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
  }
}

resource backupPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2024-04-01' = {
  parent: vault
  name: 'jt-daily-6pm-7day'
  properties: {
    backupManagementType: 'AzureIaasVM'
    instantRpRetentionRangeInDays: 2
    timeZone: 'Eastern Standard Time'
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      scheduleRunTimes: [
        '2026-01-01T18:00:00Z'
      ]
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: [
          '2026-01-01T18:00:00Z'
        ]
        retentionDuration: {
          count: 7
          durationType: 'Days'
        }
      }
    }
  }
}

var backupContainerName = 'iaasvmcontainer;iaasvmcontainerv2;${resourceGroup().name};${vmName}'
var backupItemName = 'vm;iaasvmcontainerv2;${resourceGroup().name};${vmName}'

resource vmBackup 'Microsoft.RecoveryServices/vaults/backupFabrics/protectionContainers/protectedItems@2024-04-01' = {
  name: '${vault.name}/Azure/${backupContainerName}/${backupItemName}'
  properties: {
    protectedItemType: 'Microsoft.Compute/virtualMachines'
    policyId: backupPolicy.id
    sourceResourceId: vm.id
  }
}

// -----------------------------------------------------------------------------
// Alerts
// -----------------------------------------------------------------------------
resource cpuAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: '${prefix}-alert-vm-cpu'
  location: 'global'
  tags: tags
  properties: {
    description: 'Average CPU above 80% for 5 minutes on the lab VM.'
    severity: 2
    enabled: true
    scopes: [
      vm.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'HighCPU'
          criterionType: 'StaticThresholdCriterion'
          metricNamespace: 'Microsoft.Compute/virtualMachines'
          metricName: 'Percentage CPU'
          operator: 'GreaterThan'
          threshold: 80
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
}

resource nsgChangeAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: '${prefix}-alert-nsg-rule-change'
  location: 'global'
  tags: tags
  properties: {
    description: 'Fires when anyone creates or edits an NSG rule in this resource group.'
    enabled: true
    scopes: [
      resourceGroup().id
    ]
    condition: {
      allOf: [
        {
          field: 'category'
          equals: 'Administrative'
        }
        {
          field: 'operationName'
          equals: 'Microsoft.Network/networkSecurityGroups/securityRules/write'
        }
      ]
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroup.id
        }
      ]
    }
  }
}

// -----------------------------------------------------------------------------
// Outputs
// -----------------------------------------------------------------------------
output vmName string = vm.name
output vmPublicIp string = pip.properties.ipAddress
output storageAccountName string = storage.name
output recoveryVaultName string = vault.name
output logAnalyticsWorkspace string = law.name
