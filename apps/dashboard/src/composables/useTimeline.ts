import { ref, computed } from 'vue'
import { API_BASE } from '../config'
import type { TimelineEntry } from '../types'

export type TimeFilter = '' | '30min' | '1h' | '2h' | '6h' | 'today' | 'all'
export type EntryTypeFilter = 'task-start' | 'task-done' | 'commit' | 'progress' | 'prompt'

// Module-level state survives component unmount
const entriesBySession = ref<Map<string, TimelineEntry[]>>(new Map())
const allEntries = ref<TimelineEntry[]>([])
const loading = ref(false)
const lastContainerId = ref<string | null>(null)
const timeFilter = ref<TimeFilter>('2h')
const typeFilters = ref<Set<EntryTypeFilter>>(new Set(['task-start', 'task-done', 'commit', 'progress', 'prompt']))

function sinceMs(): number {
  if (timeFilter.value === 'all') return 0
  const now = Date.now()
  switch (timeFilter.value) {
    case '30min': return now - 30 * 60 * 1000
    case '1h': return now - 60 * 60 * 1000
    case '2h': return now - 2 * 60 * 60 * 1000
    case '6h': return now - 6 * 60 * 60 * 1000
    case 'today': { const d = new Date(); d.setHours(0, 0, 0, 0); return d.getTime() }
    default: return now - 2 * 60 * 60 * 1000
  }
}

async function fetchTimeline(containerId: string, sessionIds?: string[]) {
  loading.value = true
  lastContainerId.value = containerId
  try {
    const params = new URLSearchParams({ since: String(sinceMs()) })
    if (sessionIds?.length) params.set('sessions', sessionIds.join(','))
    const res = await fetch(`${API_BASE}/dashboard/timeline/${encodeURIComponent(containerId)}?${params}`)
    if (!res.ok) return
    const entries = await res.json() as TimelineEntry[]
    allEntries.value = entries
    rebuildSessionMap(entries)
  } finally {
    loading.value = false
  }
}

function rebuildSessionMap(entries: TimelineEntry[]) {
  const map = new Map<string, TimelineEntry[]>()
  for (const e of entries) {
    const sid = e.session_id || '_unknown'
    if (!map.has(sid)) map.set(sid, [])
    map.get(sid)!.push(e)
  }
  entriesBySession.value = map
}

function addEntry(containerId: string, entry: TimelineEntry) {
  if (containerId !== lastContainerId.value) return
  allEntries.value = [...allEntries.value, entry]
  const sid = entry.session_id || '_unknown'
  const map = new Map(entriesBySession.value)
  if (!map.has(sid)) map.set(sid, [])
  map.set(sid, [...map.get(sid)!, entry])
  entriesBySession.value = map
}

const sessionIds = computed(() => Array.from(entriesBySession.value.keys()).sort())

const filteredBySession = computed(() => {
  const map = new Map<string, TimelineEntry[]>()
  for (const e of allEntries.value) {
    if (!typeFilters.value.has(e.type as EntryTypeFilter)) continue
    const sid = e.session_id || '_unknown'
    if (!map.has(sid)) map.set(sid, [])
    map.get(sid)!.push(e)
  }
  return map
})

export function useTimeline() {
  return {
    entriesBySession,
    allEntries,
    filteredBySession,
    sessionIds,
    loading,
    lastContainerId,
    timeFilter,
    typeFilters,
    fetchTimeline,
    addEntry,
  }
}
