<template>
  <div class="flex flex-col bg-slate-900" style="height: calc(100vh - 56px)">
    <!-- Header -->
    <div class="flex items-center justify-between px-4 py-2 border-b border-slate-700 bg-slate-800 shrink-0 gap-2">
      <div class="flex items-center gap-3 min-w-0">
        <h2 class="text-sm font-semibold text-slate-200 shrink-0">Timeline</h2>

        <!-- Container selector -->
        <select
          v-model="selectedContainerId"
          @change="onContainerChange"
          class="text-xs bg-slate-700 border border-slate-600 rounded px-2 py-1 text-slate-200 font-mono min-w-0 max-w-xs"
        >
          <option value="">All containers</option>
          <option v-for="c in filteredContainers" :key="c.id" :value="c.id">
            {{ containerOptionLabel(c) }}
          </option>
        </select>
      </div>

      <div class="flex items-center gap-1.5 shrink-0 flex-wrap">
        <!-- Time filter -->
        <button
          v-for="tf in TIME_FILTERS" :key="tf.value"
          @click="timeFilter = tf.value; reload()"
          class="text-xs px-1.5 py-0.5 rounded"
          :class="timeFilter === tf.value ? 'bg-amber-900/60 text-amber-300' : 'text-slate-500 hover:text-slate-300'"
        >{{ tf.label }}</button>
        <span class="text-slate-700">|</span>
        <!-- Type filters -->
        <button
          v-for="et in ENTRY_TYPES" :key="et.value"
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
    <div v-else-if="allEntries.length === 0" class="flex-1 flex items-center justify-center flex-col gap-2 text-slate-500 text-sm">
      <span>No timeline entries for this period</span>
      <button @click="timeFilter = 'all'; reload()" class="text-xs text-amber-400 hover:text-amber-300">Try "all" time range</button>
    </div>

    <!-- Timeline columns + sidebar -->
    <div v-else class="flex-1 flex overflow-hidden relative">
      <!-- Columns area -->
      <div class="flex-1 flex overflow-hidden">
        <div
          v-for="sid in visibleSessions"
          :key="sid"
          class="flex flex-col border-r border-slate-700 transition-all duration-200 relative"
          :class="columnClass(sid)"
        >
          <!-- Column header (click to select/deselect single session) -->
          <button
            @click="toggleSelectedSession(sid)"
            class="shrink-0 px-2 py-1.5 text-xs font-mono truncate border-b border-slate-700 hover:bg-slate-700/50 text-left"
            :class="selectedSession === sid ? 'bg-teal-900/40 text-teal-300 border-b-teal-600' : 'text-slate-400'"
            :title="`Session ${sid}${selectedSession === sid ? ' (click to show all)' : ' (click to focus)'}`"
          >
            <span v-if="!selectedSession || selectedSession === sid">{{ sid.slice(0, 8) }}</span>
            <span v-else class="text-slate-600">{{ sid.slice(0, 3) }}</span>
          </button>

          <!-- Entries (hidden if another session is selected) -->
          <div
            v-if="!selectedSession || selectedSession === sid"
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
            v-if="(!selectedSession || selectedSession === sid) && !isAtBottom[sid]"
            @click="scrollToBottom(sid)"
            class="absolute bottom-2 right-2 bg-slate-700/90 text-slate-300 text-xs px-2 py-1 rounded shadow hover:bg-slate-600 transition-colors z-10"
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
          <template v-if="sidebar.type === 'task' && sidebar.task">
            <div class="space-y-2">
              <div class="flex items-center gap-2"><span class="text-slate-500">Type:</span><span class="font-mono">{{ sidebar.task.task_type }}</span></div>
              <div v-if="sidebar.task.filename" class="flex items-center gap-2"><span class="text-slate-500">File:</span><span class="font-mono text-blue-400">{{ sidebar.task.filename }}</span></div>
              <div v-if="sidebar.task.description"><span class="text-slate-500">Description:</span><p class="mt-1 text-slate-300">{{ sidebar.task.description }}</p></div>
              <div class="flex items-center gap-2"><span class="text-slate-500">Status:</span><span :class="sidebar.task.status === 'done' ? 'text-green-400' : sidebar.task.status === 'underway' ? 'text-amber-400' : 'text-slate-400'">{{ sidebar.task.status }}</span></div>
            </div>
          </template>
          <template v-else-if="sidebar.type === 'git' && sidebar.hash">
            <div class="space-y-2">
              <div class="flex items-center gap-2">
                <span class="font-mono text-blue-400">{{ sidebar.hash.slice(0, 10) }}</span>
                <button @click="emit('open-git', sidebar!.hash!)" class="text-xs text-slate-500 hover:text-slate-300">Open in Git View →</button>
              </div>
              <div v-if="sidebar.subject" class="text-slate-300">{{ sidebar.subject }}</div>
            </div>
          </template>
          <template v-else-if="sidebar.type === 'log'">
            <div class="space-y-2">
              <div class="text-slate-400">{{ sidebar.text }}</div>
              <button v-if="sidebar.sessionId" @click="emit('open-session', sidebar!.sessionId!)" class="text-xs text-indigo-400 hover:text-indigo-300">Open full session log →</button>
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
  initialContainerId: string
  containers: ContainerWithState[]
  repoFilter: string
  hostFilter: string
  connectionFilter: string
}>()

const emit = defineEmits<{
  close: []
  'open-git': [hash: string]
  'open-session': [sessionId: string]
}>()

const {
  allEntries, filteredBySession, sessionIds, loading,
  timeFilter, typeFilters,
  fetchTimeline,
} = useTimeline()

const selectedContainerId = ref(props.initialContainerId)
const selectedSession = ref<string | null>(null)
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

// Filter containers using the same filters as the main dashboard
const filteredContainers = computed(() => {
  return props.containers.filter(c => {
    if (props.repoFilter && c.source_repo !== props.repoFilter) return false
    if (props.hostFilter && c.machine_hostname !== props.hostFilter) return false
    if (props.connectionFilter === 'online' && !c.connected) return false
    if (props.connectionFilter === 'offline' && c.connected) return false
    return true
  })
})

// Derive worktree label for container (matches ContainerCard logic)
function worktreeLabel(c: ContainerWithState): string {
  if ((c as any).git_worktree) {
    const wt = (c as any).git_worktree as string
    return wt.replace(/^trees\//, '').split('/').pop() ?? wt
  }
  if (c.workspace_host_path) {
    const base = c.workspace_host_path.split('/').pop() ?? ''
    if (base && base !== c.source_repo) {
      const m = base.match(new RegExp(`^${c.source_repo}\\.(.+)$`))
      return m ? `.${m[1]}` : base
    }
  }
  return ''
}

function containerOptionLabel(c: ContainerWithState): string {
  const wt = worktreeLabel(c)
  const sessions = c.active_session_ids?.length ?? 0
  const status = c.connected ? (c.status === 'busy' ? '●' : c.status === 'awaiting_input' ? '?' : '○') : '×'
  const repo = c.source_repo.split('/').pop() ?? c.source_repo
  return `${status} ${repo}${wt ? wt : ''} (${sessions} session${sessions !== 1 ? 's' : ''})`
}

const currentContainer = computed(() =>
  props.containers.find(c => c.id === selectedContainerId.value)
)

const visibleSessions = computed(() => {
  const ids = sessionIds.value
  if (selectedSession.value && ids.includes(selectedSession.value)) return ids
  return ids
})

function toggleSelectedSession(sid: string) {
  selectedSession.value = selectedSession.value === sid ? null : sid
}

function columnClass(sid: string): string {
  if (selectedSession.value && selectedSession.value !== sid) return 'w-8 shrink-0'
  return 'flex-1 min-w-0'
}

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

function onContainerChange() {
  selectedSession.value = null
  reload()
}

async function reload() {
  if (selectedContainerId.value) {
    const c = currentContainer.value
    const sessionArr = c?.active_session_ids
    await fetchTimeline(selectedContainerId.value, sessionArr)
  } else {
    // "All containers" — fetch timeline for first filtered container
    // (API requires a containerId; for all we'd need to merge)
    const first = filteredContainers.value[0]
    if (first) await fetchTimeline(first.id, first.active_session_ids)
  }
}

function formatTime(ts: number): string {
  return new Date(ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
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
  sidebar.value = { type: 'log', text: entry.summary ?? entry.prompt ?? '', sessionId: entry.session_id }
}

watch(allEntries, async () => {
  await nextTick()
  for (const [sid, el] of columnRefMap) {
    if (isAtBottom[sid] !== false) {
      el.scrollTop = el.scrollHeight
      isAtBottom[sid] = true
    }
  }
})

// If selected container is filtered out, switch to first available
watch(filteredContainers, (fc) => {
  if (fc.length && !fc.some(c => c.id === selectedContainerId.value)) {
    selectedContainerId.value = fc[0].id
    onContainerChange()
  }
})

onMounted(() => {
  reload()
  nextTick(() => {
    for (const [sid, el] of columnRefMap) {
      el.scrollTop = el.scrollHeight
      isAtBottom[sid] = true
    }
  })
})
</script>
