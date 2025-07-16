<template>
  <v-app>
    <v-container class="pa-4">
      <v-card>
        <v-card-title class="d-flex align-center">
          <v-icon class="mr-2">mdi-leaf</v-icon>
          Gardener Dashboard Editor
        </v-card-title>
        <v-card-text>
          <v-tabs v-model="tab" class="mb-4">
            <v-tab value="simple">Simple</v-tab>
            <v-tab value="advanced">Advanced</v-tab>
            <v-tab value="simulate">Simulate</v-tab>
          </v-tabs>
          <v-window v-model="tab">
            <v-window-item value="simple">
              <v-select
                v-model="selectedResource"
                :items="resourceItems"
                item-title="label"
                item-value="value"
                label="Resource"
              />
              <v-select
                v-model="namespace"
                :items="namespaceItems"
                label="Namespace"
                :disabled="!currentResource.namespaced"
              />
              <v-select
                v-model="name"
                :items="nameItems"
                label="Name"
              />
              <v-checkbox v-model="patchStatus" label="Patch status subresource" />
            </v-window-item>
            <v-window-item value="advanced">
              <v-text-field v-model="group" label="API Group" />
              <v-text-field v-model="version" label="API Version" />
              <v-text-field v-model="resource" label="Resource Type" />
              <v-text-field v-model="namespace" label="Namespace" />
              <v-text-field v-model="name" label="Name" />
              <v-text-field v-model="subresource" label="Subresource (optional)" />
            </v-window-item>
          <v-window-item value="simulate">
              <div v-for="t in tasks" :key="t.id" class="mb-6">
                <v-select
                  v-model="t.type"
                  :items="taskTypeItems"
                  item-title="label"
                  item-value="value"
                  label="Task Type"
                />
                <v-select
                  v-model="t.resource"
                  :items="taskResourceItems"
                  item-title="label"
                  item-value="value"
                  label="Resource"
                  @update:modelValue="onTaskResourceChange(t)"
                />
                <v-checkbox
                  v-model="t.allNamespaces"
                  label="All Namespaces"
                  :disabled="!t.resource.namespaced"
                  @update:modelValue="onTaskAllNamespacesChange(t)"
                />
                <v-select
                  v-model="t.namespace"
                  :items="t.namespaceItems"
                  label="Namespace"
                  :disabled="!t.resource.namespaced || t.allNamespaces"
                  @update:modelValue="onTaskNamespaceChange(t)"
                />
                <v-select
                  v-model="t.names"
                  :items="t.nameItems"
                  label="Names"
                  multiple
                  chips
                />
                <template v-if="t.type === 'toggle'">
                  <v-text-field v-model.number="t.errorRate" label="Error Rate (%)" type="number" />
                </template>
                <template v-else>
                  <v-select
                    v-model="t.opType"
                    :items="operationTypes"
                    label="Operation Type"
                  />
                  <v-text-field v-model.number="t.step" label="Step (%)" type="number" />
                  <v-checkbox v-model="t.recurring" label="Recurring" />
                </template>
                <v-text-field v-model.number="t.interval" label="Interval (s)" type="number" />
                <v-btn class="mt-2" color="primary" @click="t.running ? stopTask(t) : startTask(t)">
                  {{ t.running ? 'Stop' : 'Start' }}
                </v-btn>
              </div>
              <v-btn color="primary" @click="addTask">Add Task</v-btn>
            </v-window-item>
          </v-window>
          <v-btn color="primary" class="mt-2 mr-2" @click="load">Load</v-btn>
          <v-btn color="primary" class="mt-2" @click="save">Save</v-btn>
          <v-alert v-if="error" type="error" class="mt-4" border="start" prominent>
            {{ error }}
          </v-alert>
          <v-textarea
            v-model="yaml"
            label="YAML"
            rows="20"
            class="mt-4"
            style="font-family: monospace"
          />
        </v-card-text>
      </v-card>
    </v-container>
  </v-app>
</template>

<script setup>
import { ref, computed, watch } from 'vue'
import YAML from 'yaml'
import { VApp, VContainer, VCard, VCardTitle, VCardText, VTabs, VTab, VWindow, VWindowItem, VTextField, VSelect, VTextarea, VBtn, VAlert, VCheckbox, VIcon } from 'vuetify/components'

const group = ref('')
const version = ref('')
const resource = ref('')
const namespace = ref('')
const name = ref('')
const subresource = ref('')
const tab = ref('simple')
const patchStatus = ref(false)
const originalResource = ref(null)
const namespaceItems = ref([])
const nameItems = ref([])
const resourceOptions = [
  { label: 'Shoot', value: { group: 'core.gardener.cloud', version: 'v1beta1', resource: 'shoots', namespaced: true } },
  { label: 'Seed', value: { group: 'core.gardener.cloud', version: 'v1beta1', resource: 'seeds', namespaced: false } },
  { label: 'CloudProfile', value: { group: 'core.gardener.cloud', version: 'v1beta1', resource: 'cloudprofiles', namespaced: false } },
  { label: 'Project', value: { group: 'core.gardener.cloud', version: 'v1beta1', resource: 'projects', namespaced: false } },
]
const selectedResource = ref(null)
const resourceItems = resourceOptions
const taskResourceItems = resourceOptions.filter(r => ['shoots', 'seeds'].includes(r.value.resource))
const taskTypeItems = [
  { label: 'Toggle Health', value: 'toggle' },
  { label: 'Operation Progress', value: 'operation' }
]
const operationTypes = ['Create', 'Delete', 'Reconcile']
const currentResource = computed(() => selectedResource.value ? selectedResource.value : { namespaced: true })
const yaml = ref('')
const error = ref('')
const tasks = ref([])
// use relative path so the Vite dev server proxy or backend can serve the API
const API_BASE = ''

watch(selectedResource, async (val) => {
  if (!val) return
  group.value = val.group
  version.value = val.version
  resource.value = val.resource
  namespace.value = ''
  name.value = ''
  namespaceItems.value = []
  nameItems.value = []
  if (val.namespaced) {
    await loadNamespaces()
  } else {
    await loadNames()
  }
  if (name.value) {
    await load()
  }
})

watch(namespace, async () => {
  if (currentResource.value.namespaced && namespace.value) {
    await loadNames()
  }
  if (name.value) {
    await load()
  }
})

watch(patchStatus, async () => {
  if (tab.value === 'simple' && name.value) {
    await load()
  }
})

watch(name, async () => {
  if (name.value) {
    await load()
  }
})

async function loadNamespaces() {
  try {
    const res = await fetch(`${API_BASE}/api/resource?resource=namespaces`)
    const text = await res.text()
    if (res.ok) {
      const data = YAML.parse(text)
      namespaceItems.value = (data.items || []).map(i => i.metadata.name)
    }
  } catch (err) {
    console.error('list namespaces failed', err)
  }
}

async function loadNames() {
  try {
    const res = await fetch(`${API_BASE}/api/resource?` + buildQuery(false))
    const text = await res.text()
    if (res.ok) {
      const data = YAML.parse(text)
      nameItems.value = (data.items || []).map(i => i.metadata.name)
    }
  } catch (err) {
    console.error('list names failed', err)
  }
}

function buildQuery(includeName = true) {
  const params = new URLSearchParams({
    group: group.value,
    version: version.value,
    resource: resource.value,
    namespace: namespace.value,
    subresource: subresource.value
  })
  if (includeName) params.set('name', name.value)
  return params.toString()
}

async function load() {
  error.value = ''
  yaml.value = ''
  if (tab.value === 'simple') {
    subresource.value = patchStatus.value ? 'status' : ''
  }
  try {
    const res = await fetch(`${API_BASE}/api/resource?` + buildQuery())
    const text = await res.text()
    if (res.ok) {
      let data
      try {
        data = YAML.parse(text)
      } catch {
        data = null
      }
      originalResource.value = data
      if (tab.value === 'simple' && patchStatus.value && data) {
        yaml.value = YAML.stringify(data.status ?? {}, { indent: 2 })
      } else {
        yaml.value = text
      }
    } else {
      error.value = formatError(res, text)
    }
  } catch (err) {
    error.value = err.message || err.toString()
  }
}

async function save() {
  error.value = ''
  if (tab.value === 'simple') {
    subresource.value = patchStatus.value ? 'status' : ''
  }
  let bodyYaml = yaml.value
  if (tab.value === 'simple' && patchStatus.value) {
    try {
      const statusObj = YAML.parse(yaml.value)
      const base = originalResource.value || {}
      const objToSend = {
        apiVersion: base.apiVersion,
        kind: base.kind,
        metadata: base.metadata,
        status: statusObj,
      }
      bodyYaml = YAML.stringify(objToSend, { indent: 2 })
    } catch (e) {
      error.value = 'Invalid YAML: ' + e.message
      return
    }
  }
  try {
    const res = await fetch(`${API_BASE}/api/resource?` + buildQuery(), {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ yaml: bodyYaml })
    })
    const text = await res.text()
    if (!res.ok) {
      error.value = formatError(res, text)
    } else {
      await load()
    }
  } catch (err) {
    error.value = err.message || err.toString()
  }
}

function formatError(res, text) {
  let message = text || res.statusText
  const ct = res.headers.get('content-type') || ''
  if (ct.includes('application/json')) {
    try {
      const data = JSON.parse(text)
      message = data.error || JSON.stringify(data, null, 2)
    } catch {
      // ignore parse errors
    }
  }
  return `HTTP ${res.status} - ${message}`
}

function createTask() {
  return {
    id: Date.now() + Math.random(),
    type: 'toggle',
    resource: taskResourceItems[0].value,
    namespace: '',
    names: [],
    interval: 1,
    errorRate: 0,
    step: 1,
    opType: 'Reconcile',
    recurring: false,
    allNamespaces: false,
    running: false,
    currentProgress: 0,
    currentName: null,
    timer: null,
    namespaceItems: [],
    nameItems: []
  }
}

async function addTask() {
  const task = createTask()
  tasks.value.push(task)
  await onTaskResourceChange(task)
}

async function onTaskResourceChange(t) {
  t.namespace = ''
  t.names = []
  t.namespaceItems = []
  t.nameItems = []
  if (t.resource.namespaced) {
    await loadTaskNamespaces(t)
  } else {
    await loadTaskNames(t)
  }
}

function onTaskNamespaceChange(t) {
  if (t.resource.namespaced && t.namespace && !t.allNamespaces) {
    loadTaskNames(t)
  }
}

function onTaskAllNamespacesChange(t) {
  if (t.allNamespaces) {
    t.namespace = ''
    loadTaskNames(t)
  } else {
    t.nameItems = []
    if (t.resource.namespaced) {
      loadTaskNamespaces(t)
    } else {
      loadTaskNames(t)
    }
  }
}

async function loadTaskNamespaces(t) {
  try {
    const res = await fetch(`${API_BASE}/api/resource?resource=namespaces`)
    const text = await res.text()
    if (res.ok) {
      const data = YAML.parse(text)
      t.namespaceItems = (data.items || []).map(i => i.metadata.name)
    }
  } catch (err) {
    console.error('task list namespaces failed', err)
  }
}

async function loadTaskNames(t) {
  try {
    const params = new URLSearchParams({
      group: t.resource.group,
      version: t.resource.version,
      resource: t.resource.resource,
      namespace: t.resource.namespaced && !t.allNamespaces ? t.namespace : ''
    })
    const res = await fetch(`${API_BASE}/api/resource?` + params.toString())
    const text = await res.text()
    if (res.ok) {
      const data = YAML.parse(text)
      t.nameItems = (data.items || []).map(i =>
        t.resource.namespaced && t.allNamespaces
          ? `${i.metadata.namespace}/${i.metadata.name}`
          : i.metadata.name
      )
    }
  } catch (err) {
    console.error('task list names failed', err)
  }
}

function startTask(t) {
  if (t.running) return
  t.running = true
  if (t.type === 'toggle') {
    t.timer = setInterval(() => toggleTask(t), t.interval * 1000)
    toggleTask(t)
  } else {
    t.currentProgress = 0
    t.currentName = null
    t.timer = setInterval(() => stepOperation(t), t.interval * 1000)
    stepOperation(t)
  }
}

function stopTask(t) {
  if (t.timer) clearInterval(t.timer)
  t.timer = null
  t.running = false
}

async function getTaskNames(t) {
  if (t.names.length) return t.names
  await loadTaskNames(t)
  return t.nameItems
}

async function toggleTask(t) {
  const names = await getTaskNames(t)
  if (!names.length) return
  const item = names[Math.floor(Math.random() * names.length)]
  const makeError = Math.random() < (t.errorRate / 100)
  let ns = t.namespace
  let nm = item
  if (t.resource.namespaced && t.allNamespaces) {
    const parts = item.split('/')
    ns = parts[0]
    nm = parts[1]
  }
  await toggleResourceStatus(t, nm, ns, !makeError)
}

async function stepOperation(t) {
  if (!t.currentName) {
    const names = await getTaskNames(t)
    if (!names.length) return
    const item = names[Math.floor(Math.random() * names.length)]
    if (t.resource.namespaced && t.allNamespaces) {
      const parts = item.split('/')
      t.currentNamespace = parts[0]
      t.currentName = parts[1]
    } else {
      t.currentNamespace = t.namespace
      t.currentName = item
    }
    t.currentProgress = 0
  }
  await updateOperationProgress(t)
  t.currentProgress += t.step
  if (t.currentProgress >= 100) {
    if (t.recurring) {
      t.currentName = null
      t.currentProgress = 0
    } else {
      stopTask(t)
    }
  }
}

async function toggleResourceStatus(t, n, ns, healthy) {
  const params = new URLSearchParams({
    group: t.resource.group,
    version: t.resource.version,
    resource: t.resource.resource,
    namespace: t.resource.namespaced ? ns : '',
    name: n
  })
  try {
    const res = await fetch(`${API_BASE}/api/resource?` + params.toString())
    const text = await res.text()
    if (!res.ok) {
      console.error('get resource failed', text)
      return
    }
    const obj = YAML.parse(text)
    applyHealth(obj, healthy, t.resource.resource === 'shoots')
    const body = YAML.stringify({
      apiVersion: obj.apiVersion,
      kind: obj.kind,
      metadata: obj.metadata,
      status: obj.status
    }, { indent: 2 })
    params.set('subresource', 'status')
    const putRes = await fetch(`${API_BASE}/api/resource?` + params.toString(), {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ yaml: body })
    })
    await putRes.text()
    if (t.resource.resource === 'shoots') {
      params.delete('subresource')
      const labelPatch = YAML.stringify({
        metadata: { labels: { 'shoot.gardener.cloud/status': healthy ? 'healthy' : 'unhealthy' } }
      }, { indent: 2 })
      await fetch(`${API_BASE}/api/resource?` + params.toString(), {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/merge-patch+json' },
        body: JSON.stringify({ yaml: labelPatch })
      })
    }
  } catch (err) {
    console.error('toggle resource failed', err)
  }
}

async function updateOperationProgress(t) {
  const params = new URLSearchParams({
    group: t.resource.group,
    version: t.resource.version,
    resource: t.resource.resource,
    namespace: t.resource.namespaced ? t.currentNamespace : '',
    name: t.currentName,
    subresource: 'status'
  })
  try {
    const res = await fetch(`${API_BASE}/api/resource?` + params.toString())
    const text = await res.text()
    if (!res.ok) {
      console.error('get resource failed', text)
      return
    }
    const obj = YAML.parse(text)
    const now = new Date().toISOString()
    if (!obj.status) obj.status = {}
    obj.status.lastOperation = {
      description: t.currentProgress + t.step >= 100 ? 'Operation succeeded.' : 'Operation in progress',
      lastUpdateTime: now,
      progress: Math.min(100, t.currentProgress + t.step),
      state: t.currentProgress + t.step >= 100 ? 'Succeeded' : 'Processing',
      type: t.opType
    }
    const body = YAML.stringify({
      apiVersion: obj.apiVersion,
      kind: obj.kind,
      metadata: obj.metadata,
      status: obj.status
    }, { indent: 2 })
    const putRes = await fetch(`${API_BASE}/api/resource?` + params.toString(), {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ yaml: body })
    })
    await putRes.text()
  } catch (err) {
    console.error('update operation failed', err)
  }
}

function applyHealth(obj, healthy, isShoot) {
  const now = new Date().toISOString()
  if (!obj.status) obj.status = {}
  if (Array.isArray(obj.status.conditions)) {
    const conds = obj.status.conditions
    let changed = false
    conds.forEach((c, i) => {
      if (healthy) {
        c.status = 'True'
      } else {
        c.status = (i === 0 || Math.random() > 0.5) ? 'False' : 'True'
        if (c.status === 'False') changed = true
      }
      c.lastUpdateTime = now
      c.lastTransitionTime = c.lastTransitionTime || now
    })
    if (!healthy && !changed && conds.length) {
      conds[0].status = 'False'
    }
  }
  if (Array.isArray(obj.status.constraints)) {
    const cons = obj.status.constraints
    let changed = false
    cons.forEach((c, i) => {
      if (healthy) {
        c.status = 'True'
      } else {
        c.status = (i === 0 || Math.random() > 0.5) ? 'False' : 'True'
        if (c.status === 'False') changed = true
      }
      c.lastUpdateTime = now
      c.lastTransitionTime = c.lastTransitionTime || now
    })
    if (!healthy && !changed && cons.length) {
      cons[0].status = 'False'
    }
  }
  obj.status.lastOperation = {
    description: healthy
      ? 'Shoot cluster has been successfully reconciled.'
      : 'Error occurred during shoot reconciliation.',
    lastUpdateTime: now,
    progress: 100,
    state: healthy ? 'Succeeded' : 'Error',
    type: 'Reconcile'
  }
  if (isShoot) {
    if (!obj.metadata) obj.metadata = {}
    if (!obj.metadata.labels) obj.metadata.labels = {}
    obj.metadata.labels['shoot.gardener.cloud/status'] = healthy ? 'healthy' : 'unhealthy'
  }
}
</script>
