<template>
  <Teleport to="body">
    <div class="fixed inset-0 z-[200] flex items-center justify-center bg-black/60" @click.self="emit('close')">
      <div class="bg-slate-800 border border-slate-600 rounded-xl shadow-2xl p-5 w-[460px] max-w-[95vw]">
        <div class="flex items-center justify-between mb-4">
          <h3 class="text-sm font-semibold text-slate-200">
            {{ mode === 'move' ? 'Move' : 'Copy' }} task to another container
          </h3>
          <button @click="emit('close')" class="text-slate-400 hover:text-slate-200 text-lg leading-none">✕</button>
        </div>

        <!-- Task summary -->
        <div class="mb-4 px-3 py-2 bg-slate-900/60 rounded border border-slate-700 text-xs text-slate-300">
          <span class="font-mono text-slate-400">{{ task.task_type }}:</span>
          <span class="ml-1">{{ task.filename ?? task.description }}</span>
          <span v-if="subtaskCount > 0" class="ml-2 text-slate-500">(+ {{ subtaskCount }} subtask{{ subtaskCount === 1 ? '' : 's' }})</span>
        </div>

        <!-- Mode selector -->
        <div class="mb-4 flex gap-2">
          <button
            @click="mode = 'copy'"
            class="flex-1 text-xs py-1.5 rounded border"
            :class="mode === 'copy' ? 'bg-blue-700/40 border-blue-500 text-blue-200' : 'border-slate-600 text-slate-400 hover:border-slate-400'"
          >Copy</button>
          <button
            @click="mode = 'move'"
            class="flex-1 text-xs py-1.5 rounded border"
            :class="mode === 'move' ? 'bg-orange-700/40 border-orange-500 text-orange-200' : 'border-slate-600 text-slate-400 hover:border-slate-400'"
          >Move</button>
        </div>

        <!-- Filters -->
        <div class="mb-3 flex gap-2 flex-wrap">
          <select
            v-model="filterProject"
            class="text-xs text-slate-200 bg-slate-700 border border-slate-600 rounded px-1.5 py-0.5 cursor-pointer min-w-0 flex-1"
            title="Filter by project"
          >
            <option value="">All projects</option>
            <option v-for="p in allProjects" :key="p" :value="p">{{ p.split('/').pop() }}</option>
          </select>
          <select
            v-model="filterHost"
            class="text-xs text-slate-200 bg-slate-700 border border-slate-600 rounded px-1.5 py-0.5 cursor-pointer min-w-0 flex-1"
            title="Filter by host"
          >
            <option value="">All hosts</option>
            <option v-for="h in allHosts" :key="h" :value="h">{{ h }}</option>
          </select>
          <div class="flex rounded border border-slate-600 overflow-hidden text-xs shrink-0">
            <button
              @click="filterOnline = true"
              class="px-2 py-0.5"
              :class="filterOnline ? 'bg-green-700/40 text-green-300' : 'text-slate-500 hover:text-slate-300'"
            >Online</button>
            <button
              @click="filterOnline = false"
              class="px-2 py-0.5 border-l border-slate-600"
              :class="!filterOnline ? 'bg-slate-600 text-slate-200' : 'text-slate-500 hover:text-slate-300'"
            >All</button>
          </div>
        </div>

        <!-- Container selector -->
        <div class="mb-1 text-xs text-slate-400">Target container</div>
        <select
          v-model="selectedContainerId"
          class="w-full mb-4 bg-slate-700 border border-slate-600 rounded px-2 py-1.5 text-xs text-slate-200 focus:outline-none focus:border-slate-400"
        >
          <option value="">— select container —</option>
          <optgroup v-for="(group, host) in filteredContainerGroups" :key="host" :label="String(host)">
            <option v-for="c in group" :key="c.id" :value="c.id">
              {{ c.container_hostname }} ({{ c.source_repo.split('/').pop() }}){{ c.connected ? '' : ' [offline]' }}
            </option>
          </optgroup>
        </select>

        <p v-if="mode === 'move'" class="text-xs text-amber-400/80 mb-4">
          The task will be copied to the target container first; once confirmed successful it will be deleted from this container.
        </p>

        <p v-if="errorMsg" class="text-xs text-red-400 mb-3">{{ errorMsg }}</p>

        <div class="flex gap-2 justify-end">
          <button @click="emit('close')" class="text-xs px-3 py-1.5 rounded border border-slate-600 text-slate-400 hover:text-slate-200">
            Cancel
          </button>
          <button
            @click="confirm"
            :disabled="!selectedContainerId || working"
            class="text-xs px-3 py-1.5 rounded border font-medium"
            :class="selectedContainerId && !working
              ? mode === 'move'
                ? 'bg-orange-700 border-orange-600 text-orange-100 hover:bg-orange-600'
                : 'bg-blue-700 border-blue-600 text-blue-100 hover:bg-blue-600'
              : 'bg-slate-700 border-slate-600 text-slate-500 cursor-not-allowed'"
          >{{ working ? (mode === 'move' ? 'Moving…' : 'Copying…') : (mode === 'move' ? 'Move' : 'Copy') }}</button>
        </div>
      </div>
    </div>
  </Teleport>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { usePlanq } from '../composables/usePlanq'
import { useContainers } from '../composables/useContainers'
import type { PlanqTask } from '../types'

const props = defineProps<{
  task: PlanqTask
  containerId: string
  allTasks: PlanqTask[]
  initialMode?: 'copy' | 'move'
  initialTargetContainerId?: string
}>()

const emit = defineEmits<{
  'close': []
  'done': [mode: 'copy' | 'move']
}>()

const { copyTaskTo, deleteTask } = usePlanq()
const { containers } = useContainers()

const mode = ref<'copy' | 'move'>(props.initialMode ?? 'copy')
const selectedContainerId = ref('')
const working = ref(false)
const errorMsg = ref('')

const subtaskCount = computed(() =>
  props.allTasks.filter(t => t.parent_task_id === props.task.id).length
)

// Source container info (for default filter values)
const sourceContainer = computed(() => containers.value.get(props.containerId))

// All candidate containers (excluding source)
const candidateContainers = computed(() =>
  [...containers.value.values()].filter(c => c.id !== props.containerId)
)

const allHosts = computed(() => {
  const hosts = new Set<string>()
  for (const c of candidateContainers.value) hosts.add(c.machine_hostname)
  return [...hosts].sort()
})

const allProjects = computed(() => {
  const projects = new Set<string>()
  for (const c of candidateContainers.value) projects.add(c.source_repo)
  return [...projects].sort()
})

// Filter state — initialized in onMounted to use reactive container data
const filterHost = ref('')
const filterProject = ref('')
const filterOnline = ref(true)

onMounted(() => {
  if (props.initialTargetContainerId) {
    // Drag case: pre-select and filter to the target container
    const target = containers.value.get(props.initialTargetContainerId)
    if (target) {
      filterHost.value = target.machine_hostname
      filterProject.value = target.source_repo
      filterOnline.value = target.connected
      selectedContainerId.value = props.initialTargetContainerId
      return
    }
  }
  // Default: filter by same project as source, online only
  filterProject.value = sourceContainer.value?.source_repo ?? ''
  filterOnline.value = true
})

const filteredContainerGroups = computed(() => {
  const groups: Record<string, Array<{ id: string; container_hostname: string; source_repo: string; connected: boolean }>> = {}
  for (const c of candidateContainers.value) {
    if (filterHost.value && c.machine_hostname !== filterHost.value) continue
    if (filterProject.value && c.source_repo !== filterProject.value) continue
    if (filterOnline.value && !c.connected) continue
    if (!groups[c.machine_hostname]) groups[c.machine_hostname] = []
    groups[c.machine_hostname].push({ id: c.id, container_hostname: c.container_hostname, source_repo: c.source_repo, connected: c.connected })
  }
  return groups
})

async function confirm() {
  if (!selectedContainerId.value || working.value) return
  working.value = true
  errorMsg.value = ''

  const result = await copyTaskTo(props.containerId, props.task.id, selectedContainerId.value)
  if (!result.ok) {
    errorMsg.value = 'Failed to copy task. Is the target container connected?'
    working.value = false
    return
  }

  if (mode.value === 'move') {
    // Delete original task and its subtasks (delete root — server cascades or we delete all)
    const subtasks = props.allTasks.filter(t => t.parent_task_id === props.task.id)
    for (const sub of subtasks) await deleteTask(props.containerId, sub.id)
    await deleteTask(props.containerId, props.task.id)
  }

  working.value = false
  emit('done', mode.value)
  emit('close')
}
</script>
