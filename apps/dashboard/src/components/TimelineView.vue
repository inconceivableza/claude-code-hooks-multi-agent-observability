<template>
  <div class="fixed inset-0 z-40 flex flex-col bg-slate-900">
    <!-- Header -->
    <div class="flex items-center justify-between px-4 py-2 border-b border-slate-700 bg-slate-800 shrink-0">
      <div class="flex items-center gap-3">
        <h2 class="text-sm font-semibold text-slate-200">Timeline</h2>
        <span v-if="containerLabel" class="text-xs text-slate-400 font-mono">{{ containerLabel }}</span>
      </div>
      <div class="flex items-center gap-2">
        <!-- Time filter -->
        <button
          v-for="tf in TIME_FILTERS"
          :key="tf.value"
          @click="timeFilter = tf.value; reload()"
          class="text-xs px-1.5 py-0.5 rounded"
          :class="timeFilter === tf.value ? 'bg-amber-900/60 text-amber-300' : 'text-slate-500 hover:text-slate-300'"
        >{{ tf.label }}</button>
        <span class="text-slate-700">|</span>
        <!-- Type filters -->
        <button
          v-for="et in ENTRY_TYPES"
          :key="et.value"
          @click="toggleTypeFilter(et.value)"
          class="text-xs px-1.5 py-0.5 rounded"
          :class="typeFilters.has(et.value) ? et.activeClass : 'text-slate-600 hover:text-slate-400'"
        >{{ et.label }}</button>
        <span class="text-slate-700">|</span>
        <button @click="emit('close')" class="text-slate-500 hover:text-slate-200 text-sm px-1">✕</button>
      </div>
    </div>

    <!-- Loading -->
    <div v-if="loading" class="flex-1 flex items-center justify-center text-slate-500 text-sm">Loading timeline...</div>

    <!-- Empty -->
    <div v-else-if="allEntries.length === 0" class="flex-1 flex items-center justify-center text-slate-500 text-sm">No timeline entries for this period</div>

    <!-- Timeline columns -->
    <div v-else class="flex-1 flex overflow-hidden">
      <div
        v-for="sid in visibleSessions"
        :key="sid"
        class="flex flex-col border-r border-slate-700 transition-all duration-200"
        :class="maximizedSession && maximizedSession !== sid ? 'w-8 shrink-0' : 'flex-1 min-w-0'"
      >
        <!-- Column header -->
        <button
          @click="maximizedSession = maximizedSession === sid ? null : sid"
          class="shrink-0 px-2 py-1.5 text-xs font-mono truncate border-b border-slate-700 hover:bg-slate-700/50 text-left"
          :class="maximizedSession === sid ? 'bg-slate-700 text-slate-200' : 'text-slate-400'"
          :title="sid"
        >
          <span v-if="!maximizedSession || maximizedSession === sid">{{ sid.slice(0, 8) }}</span>
          <span v-else class="text-slate-600">{{ sid.slice(0, 2) }}</span>
        </button>

        <!-- Entries (hidden if minimized) -->
        <div
          v-if="!maximizedSession || maximizedSession === sid"
          ref="columnRefs"
          class="flex-1 overflow-y-auto px-2 py-1 space-y-0.5 text-xs"
        >
          <div
            v-for="(entry, i) in (filteredBySession.get(sid) ?? [])"
            :key="i"
            class="py-0.5 leading-tight"
            :class="entryIndent(entry, filteredBySession.get(sid) ?? [], i)"
          >
            <!-- Task start -->
            <div v-if="entry.type === 'task-start'" class="flex items-center gap-1 text-teal-400 font-medium cursor-pointer hover:text-teal-300" @click="emit('open-task', entry.task!)">
              <span>▶</span>
              <span class="text-slate-500 text-[10px]">{{ entry.task?.task_type }}</span>
              <span class="truncate">{{ entry.task?.filename ?? entry.task?.description }}</span>
            </div>

            <!-- Task done -->
            <div v-else-if="entry.type === 'task-done'" class="flex items-center gap-1 text-green-400 cursor-pointer hover:text-green-300" @click="emit('open-task', entry.task!)">
              <span>✓</span>
              <span class="truncate">{{ entry.task?.filename ?? entry.task?.description }}</span>
            </div>

            <!-- Commit -->
            <div v-else-if="entry.type === 'commit'" class="flex items-center gap-1 text-blue-400 cursor-pointer hover:text-blue-300" @click="emit('open-git', entry.commit!.hash)">
              <span>●</span>
              <span class="font-mono text-blue-500">{{ entry.commit!.hash.slice(0, 7) }}</span>
              <span class="text-slate-400 truncate">{{ entry.commit!.subject.slice(0, 60) }}</span>
            </div>

            <!-- Progress -->
            <div v-else-if="entry.type === 'progress'" class="flex items-center gap-1 text-slate-500" :title="entry.summary">
              <span>·</span>
              <span class="truncate">{{ entry.summary?.slice(0, 80) }}</span>
            </div>

            <!-- Prompt -->
            <div v-else-if="entry.type === 'prompt'" class="flex items-center gap-1 text-slate-600" :title="entry.prompt">
              <span>»</span>
              <span class="truncate italic">{{ entry.prompt?.slice(0, 60) }}</span>
            </div>

            <!-- Timestamp -->
            <span class="text-[10px] text-slate-700 ml-auto shrink-0 pl-1">{{ formatTime(entry.timestamp) }}</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, ref, onMounted, watch, nextTick } from 'vue'
import { useTimeline, type TimeFilter, type EntryTypeFilter } from '../composables/useTimeline'
import type { TimelineEntry, ContainerWithState } from '../types'

const props = defineProps<{
  containerId: string
  container?: ContainerWithState
}>()

const emit = defineEmits<{
  close: []
  'open-task': [task: { id: number; task_type: string; filename: string | null; description: string | null; status: string }]
  'open-git': [hash: string]
  'open-session': [sessionId: string]
}>()

const {
  allEntries, filteredBySession, sessionIds, loading,
  timeFilter, typeFilters, sessionFilters, maximizedSession,
  fetchTimeline, addEntry,
} = useTimeline()

const columnRefs = ref<HTMLElement[]>([])

const containerLabel = computed(() => {
  const c = props.container
  if (!c) return props.containerId.slice(0, 8)
  return `${c.machine_hostname ?? ''}${c.container_hostname ? ':' + c.container_hostname : ''}`
})

const visibleSessions = computed(() => {
  const ids = sessionIds.value
  if (sessionFilters.value.size > 0) return ids.filter(s => sessionFilters.value.has(s))
  return ids
})

const TIME_FILTERS: Array<{ value: TimeFilter; label: string }> = [
  { value: '30min', label: '30m' },
  { value: '1h', label: '1h' },
  { value: '2h', label: '2h' },
  { value: '6h', label: '6h' },
  { value: 'today', label: 'today' },
  { value: 'all', label: 'all' },
]

const ENTRY_TYPES: Array<{ value: EntryTypeFilter; label: string; activeClass: string }> = [
  { value: 'task-start', label: '▶ tasks', activeClass: 'bg-teal-900/50 text-teal-300' },
  { value: 'task-done', label: '✓ done', activeClass: 'bg-green-900/50 text-green-300' },
  { value: 'commit', label: '● commits', activeClass: 'bg-blue-900/50 text-blue-300' },
  { value: 'progress', label: '· progress', activeClass: 'bg-slate-700 text-slate-300' },
  { value: 'prompt', label: '» prompts', activeClass: 'bg-slate-700 text-slate-400' },
]

function toggleTypeFilter(t: EntryTypeFilter) {
  const s = new Set(typeFilters.value)
  if (s.has(t)) s.delete(t); else s.add(t)
  typeFilters.value = s
}

function reload() {
  const sessionArr = props.container?.active_session_ids
  fetchTimeline(props.containerId, sessionArr)
}

function formatTime(ts: number): string {
  const d = new Date(ts)
  return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
}

function entryIndent(entry: TimelineEntry, entries: TimelineEntry[], idx: number): string {
  // Indent non-task entries under task headings
  if (entry.type === 'task-start' || entry.type === 'task-done') return ''
  // Check if there's a preceding task-start
  for (let i = idx - 1; i >= 0; i--) {
    if (entries[i].type === 'task-start') return 'pl-3'
    if (entries[i].type === 'task-done') return ''
  }
  return ''
}

// Auto-scroll to bottom when new entries arrive
watch(allEntries, async () => {
  await nextTick()
  for (const el of columnRefs.value) {
    if (el && el.scrollHeight - el.scrollTop - el.clientHeight < 100) {
      el.scrollTop = el.scrollHeight
    }
  }
})

onMounted(() => reload())

// Expose addEntry for WebSocket handler
defineExpose({ addEntry })
</script>
