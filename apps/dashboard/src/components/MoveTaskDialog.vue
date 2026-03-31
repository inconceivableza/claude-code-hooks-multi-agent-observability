<template>
  <Teleport to="body">
    <div class="fixed inset-0 z-[200] flex items-center justify-center bg-black/60" @click.self="emit('close')">
      <div class="bg-slate-800 border border-slate-600 rounded-xl shadow-2xl p-5 w-[420px] max-w-[95vw]">
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

        <!-- Container selector -->
        <div class="mb-1 text-xs text-slate-400">Target container</div>
        <select
          v-model="selectedContainerId"
          class="w-full mb-4 bg-slate-700 border border-slate-600 rounded px-2 py-1.5 text-xs text-slate-200 focus:outline-none focus:border-slate-400"
        >
          <option value="">— select container —</option>
          <optgroup v-for="(group, host) in containerGroups" :key="host" :label="String(host)">
            <option v-for="c in group" :key="c.id" :value="c.id">
              {{ c.container_hostname }} ({{ c.source_repo }}){{ c.connected ? '' : ' [offline]' }}
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
import { ref, computed } from 'vue'
import { usePlanq } from '../composables/usePlanq'
import { useContainers } from '../composables/useContainers'
import type { PlanqTask } from '../types'

const props = defineProps<{
  task: PlanqTask
  containerId: string
  allTasks: PlanqTask[]
  initialMode?: 'copy' | 'move'
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

// Group containers by hostname, excluding the current container
const containerGroups = computed(() => {
  const groups: Record<string, Array<{ id: string; container_hostname: string; source_repo: string; connected: boolean }>> = {}
  for (const c of containers.value.values()) {
    if (c.id === props.containerId) continue
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
