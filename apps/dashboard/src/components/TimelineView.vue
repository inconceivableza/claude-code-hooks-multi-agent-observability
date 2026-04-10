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
        <!-- Session filter (compact: show session count if >1) -->
        <button
          v-if="sessionIds.length > 1"
          @click="showSessionPicker = !showSessionPicker"
          class="text-xs px-1.5 py-0.5 rounded"
          :class="sessionFilters.size > 0 ? 'bg-purple-900/50 text-purple-300' : 'text-slate-500 hover:text-slate-300'"
        >{{ sessionFilters.size > 0 ? `${sessionFilters.size}/${sessionIds.length} sessions` : `${sessionIds.length} sessions` }}</button>
        <span v-if="sessionIds.length > 1" class="text-slate-700">|</span>
        <button @click="emit('close')" class="text-slate-500 hover:text-slate-200 text-sm px-1">✕</button>
      </div>
    </div>

    <!-- Session picker dropdown -->
    <div v-if="showSessionPicker" class="absolute top-10 right-20 z-50 bg-slate-800 border border-slate-600 rounded shadow-xl p-2 max-h-60 overflow-y-auto">
      <button @click="sessionFilters = new Set(); showSessionPicker = false" class="text-xs text-slate-400 hover:text-slate-200 mb-1 block w-full text-left px-1">Show all</button>
      <label
        v-for="sid in sessionIds" :key="sid"
        class="flex items-center gap-1.5 text-xs py-0.5 px-1 hover:bg-slate-700/50 rounded cursor-pointer"
      >
        <input
          type="checkbox"
          :checked="sessionFilters.size === 0 || sessionFilters.has(sid)"
          @change="toggleSessionFilter(sid)"
          class="rounded"
        />
        <span class="font-mono text-slate-300">{{ sid.slice(0, 8) }}</span>
      </label>
    </div>

    <!-- Loading -->
    <div v-if="loading" class="flex-1 flex items-center justify-center text-slate-500 text-sm">Loading timeline...</div>

    <!-- Empty -->
    <div v-else-if="allEntries.length === 0" class="flex-1 flex items-center justify-center flex-col gap-2 text-slate-500 text-sm">
      <span>No timeline entries for this period</span>
      <button @click="timeFilter = 'all'; reload()" class="text-xs text-amber-400 hover:text-amber-300">Try "all" time range</button>
    </div>

    <!-- Timeline columns + sidebar -->
    <div v-else class="flex-1 flex overflow-hidden relative">
      <!-- Columns area -->
      <div class="flex-1 flex overflow-hidden" :class="sidebar ? 'mr-0' : ''">
        <div
          v-for="sid in visibleSessions"
          :key="sid"
          class="flex flex-col border-r border-slate-700 transition-all duration-200 relative"
          :class="columnClass(sid)"
        >
          <!-- Column header -->
          <button
            @click="maximizedSession = maximizedSession === sid ? null : sid"
            @dblclick="maximizedSession = null"
            class="shrink-0 px-2 py-1.5 text-xs font-mono truncate border-b border-slate-700 hover:bg-slate-700/50 text-left"
            :class="maximizedSession === sid ? 'bg-slate-700 text-slate-200' : 'text-slate-400'"
            :title="`${sid} — click to ${maximizedSession === sid ? 'restore' : 'maximize'}, double-click to restore all`"
          >
            <span v-if="!maximizedSession || maximizedSession === sid">{{ sid.slice(0, 8) }}</span>
            <span v-else class="text-slate-600 writing-mode-vertical">{{ sid.slice(0, 4) }}</span>
          </button>

          <!-- Entries (hidden if minimized) -->
          <div
            v-if="!maximizedSession || maximizedSession === sid"
            :ref="el => setColumnRef(sid, el as HTMLElement)"
            class="flex-1 overflow-y-auto px-2 py-1 text-xs"
            @scroll="onColumnScroll(sid, $event)"
          >
            <div
              v-for="(entry, i) in (filteredBySession.get(sid) ?? [])"
              :key="entry.timestamp + '-' + i"
              class="py-0.5 leading-tight flex items-baseline gap-1"
              :class="entryIndent(entry, filteredBySession.get(sid) ?? [], i)"
            >
              <!-- Task start -->
              <template v-if="entry.type === 'task-start'">
                <span class="text-[10px] text-slate-700 shrink-0 w-10 text-right">{{ formatTime(entry.timestamp) }}</span>
                <div class="flex items-center gap-1 text-teal-400 font-medium cursor-pointer hover:text-teal-300 min-w-0" @click="openTaskSidebar(entry)">
                  <span>▶</span>
                  <span class="text-slate-500 text-[10px]">{{ entry.task?.task_type }}</span>
                  <span class="truncate">{{ entry.task?.filename ?? entry.task?.description }}</span>
                </div>
              </template>

              <!-- Task done -->
              <template v-else-if="entry.type === 'task-done'">
                <span class="text-[10px] text-slate-700 shrink-0 w-10 text-right">{{ formatTime(entry.timestamp) }}</span>
                <div class="flex items-center gap-1 text-green-400 cursor-pointer hover:text-green-300 min-w-0" @click="openTaskSidebar(entry)">
                  <span>✓</span>
                  <span class="truncate">{{ entry.task?.filename ?? entry.task?.description }}</span>
                </div>
              </template>

              <!-- Commit -->
              <template v-else-if="entry.type === 'commit'">
                <span class="text-[10px] text-slate-700 shrink-0 w-10 text-right">{{ formatTime(entry.timestamp) }}</span>
                <div class="flex items-center gap-1 text-blue-400 cursor-pointer hover:text-blue-300 min-w-0" @click="openGitSidebar(entry)">
                  <span>●</span>
                  <span class="font-mono text-blue-500">{{ entry.commit!.hash.slice(0, 7) }}</span>
                  <span class="text-slate-400 truncate">{{ entry.commit!.subject.slice(0, 60) }}</span>
                </div>
              </template>

              <!-- Progress -->
              <template v-else-if="entry.type === 'progress'">
                <span class="text-[10px] text-slate-700 shrink-0 w-10 text-right">{{ formatTime(entry.timestamp) }}</span>
                <div class="flex items-center gap-1 text-slate-500 min-w-0 cursor-pointer hover:text-slate-400" @click="openLogSidebar(entry)" :title="entry.summary">
                  <span>·</span>
                  <span class="truncate">{{ entry.summary?.slice(0, 80) }}</span>
                </div>
              </template>

              <!-- Prompt -->
              <template v-else-if="entry.type === 'prompt'">
                <span class="text-[10px] text-slate-700 shrink-0 w-10 text-right">{{ formatTime(entry.timestamp) }}</span>
                <div class="flex items-center gap-1 text-slate-600 min-w-0 cursor-pointer hover:text-slate-500" @click="openLogSidebar(entry)" :title="entry.prompt">
                  <span>»</span>
                  <span class="truncate italic">{{ entry.prompt?.slice(0, 60) }}</span>
                </div>
              </template>
            </div>
          </div>

          <!-- Scroll-to-bottom button -->
          <button
            v-if="(!maximizedSession || maximizedSession === sid) && !isAtBottom[sid]"
            @click="scrollToBottom(sid)"
            class="absolute bottom-2 right-2 bg-slate-700/90 text-slate-300 text-xs px-2 py-1 rounded shadow hover:bg-slate-600 transition-colors"
          >↓ Latest</button>
        </div>
      </div>

      <!-- Sidebar panel -->
      <div
        v-if="sidebar"
        class="w-[400px] shrink-0 border-l border-slate-700 bg-slate-800 flex flex-col overflow-hidden"
      >
        <div class="flex items-center justify-between px-3 py-2 border-b border-slate-700 shrink-0">
          <span class="text-xs font-semibold text-slate-300">{{ sidebarTitle }}</span>
          <button @click="sidebar = null" class="text-slate-500 hover:text-slate-200 text-xs">✕</button>
        </div>
        <div class="flex-1 overflow-y-auto p-3 text-xs text-slate-300">
          <!-- Task sidebar -->
          <template v-if="sidebar.type === 'task' && sidebar.task">
            <div class="space-y-2">
              <div class="flex items-center gap-2">
                <span class="text-slate-500">Type:</span>
                <span class="font-mono">{{ sidebar.task.task_type }}</span>
              </div>
              <div v-if="sidebar.task.filename" class="flex items-center gap-2">
                <span class="text-slate-500">File:</span>
                <span class="font-mono text-blue-400">{{ sidebar.task.filename }}</span>
              </div>
              <div v-if="sidebar.task.description">
                <span class="text-slate-500">Description:</span>
                <p class="mt-1 text-slate-300">{{ sidebar.task.description }}</p>
              </div>
              <div class="flex items-center gap-2">
                <span class="text-slate-500">Status:</span>
                <span :class="sidebar.task.status === 'done' ? 'text-green-400' : sidebar.task.status === 'underway' ? 'text-amber-400' : 'text-slate-400'">{{ sidebar.task.status }}</span>
              </div>
            </div>
          </template>

          <!-- Git sidebar -->
          <template v-else-if="sidebar.type === 'git' && sidebar.hash">
            <div class="space-y-2">
              <div class="flex items-center gap-2">
                <span class="font-mono text-blue-400">{{ sidebar.hash.slice(0, 10) }}</span>
                <button @click="emit('open-git', sidebar!.hash)" class="text-xs text-slate-500 hover:text-slate-300">Open in Git View →</button>
              </div>
              <div v-if="sidebar.subject" class="text-slate-300">{{ sidebar.subject }}</div>
            </div>
          </template>

          <!-- Log sidebar -->
          <template v-else-if="sidebar.type === 'log'">
            <div class="space-y-2">
              <div class="text-slate-400">{{ sidebar.text }}</div>
              <button
                v-if="sidebar.sessionId"
                @click="emit('open-session', sidebar!.sessionId)"
                class="text-xs text-indigo-400 hover:text-indigo-300"
              >Open full session log →</button>
            </div>
          </template>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { computed, ref, onMounted, watch, nextTick, reactive } from 'vue'
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
  fetchTimeline,
} = useTimeline()

const showSessionPicker = ref(false)
const columnRefMap = new Map<string, HTMLElement>()
const isAtBottom = reactive<Record<string, boolean>>({})

const sidebar = ref<{
  type: 'task' | 'git' | 'log'
  task?: { id: number; task_type: string; filename: string | null; description: string | null; status: string }
  hash?: string
  subject?: string
  text?: string
  sessionId?: string
} | null>(null)

const sidebarTitle = computed(() => {
  if (!sidebar.value) return ''
  if (sidebar.value.type === 'task') return 'Task Detail'
  if (sidebar.value.type === 'git') return 'Commit'
  return 'Session Log'
})

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

function toggleSessionFilter(sid: string) {
  const s = new Set(sessionFilters.value)
  if (s.has(sid)) s.delete(sid); else s.add(sid)
  sessionFilters.value = s
}

function columnClass(sid: string): string {
  if (maximizedSession.value && maximizedSession.value !== sid) return 'w-8 shrink-0'
  return 'flex-1 min-w-0'
}

function setColumnRef(sid: string, el: HTMLElement | null) {
  if (el) columnRefMap.set(sid, el); else columnRefMap.delete(sid)
}

function onColumnScroll(sid: string, e: Event) {
  const el = e.target as HTMLElement
  isAtBottom[sid] = el.scrollHeight - el.scrollTop - el.clientHeight < 50
}

function scrollToBottom(sid: string) {
  const el = columnRefMap.get(sid)
  if (el) { el.scrollTop = el.scrollHeight; isAtBottom[sid] = true }
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
  if (entry.type === 'task-start' || entry.type === 'task-done') return ''
  for (let i = idx - 1; i >= 0; i--) {
    if (entries[i].type === 'task-start') return 'pl-3'
    if (entries[i].type === 'task-done') return ''
  }
  return ''
}

function openTaskSidebar(entry: TimelineEntry) {
  if (entry.task) sidebar.value = { type: 'task', task: entry.task }
}

function openGitSidebar(entry: TimelineEntry) {
  if (entry.commit) sidebar.value = { type: 'git', hash: entry.commit.hash, subject: entry.commit.subject }
}

function openLogSidebar(entry: TimelineEntry) {
  sidebar.value = {
    type: 'log',
    text: entry.summary ?? entry.prompt ?? '',
    sessionId: entry.session_id,
  }
}

// Auto-scroll to bottom when new entries arrive (only if already at bottom)
watch(allEntries, async () => {
  await nextTick()
  for (const [sid, el] of columnRefMap) {
    if (isAtBottom[sid] !== false) {
      el.scrollTop = el.scrollHeight
      isAtBottom[sid] = true
    }
  }
})

onMounted(() => {
  reload()
  // Initial scroll to bottom
  nextTick(() => {
    for (const [sid, el] of columnRefMap) {
      el.scrollTop = el.scrollHeight
      isAtBottom[sid] = true
    }
  })
})
</script>
