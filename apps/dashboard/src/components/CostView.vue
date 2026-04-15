<template>
  <div class="flex flex-col bg-slate-900" style="height: calc(100vh - 56px)">
    <!-- Header / filters -->
    <div class="flex items-center justify-between px-4 py-2 border-b border-slate-700 bg-slate-800 shrink-0 gap-2">
      <h2 class="text-sm font-semibold text-slate-200 shrink-0">Costs</h2>
      <div class="flex items-center gap-2 flex-wrap text-xs">
        <!-- Date range -->
        <select v-model="dateRange" @change="reload" class="bg-slate-700 border border-slate-600 rounded px-2 py-1 text-slate-200">
          <option value="7d">Last 7 days</option>
          <option value="14d">Last 14 days</option>
          <option value="30d">Last 30 days</option>
          <option value="all">All time</option>
        </select>
        <!-- Model filter -->
        <select v-model="modelFilter" @change="reload" class="bg-slate-700 border border-slate-600 rounded px-2 py-1 text-slate-200">
          <option value="">All models</option>
          <option v-for="m in availableModels" :key="m" :value="m">{{ m }}</option>
        </select>
        <!-- Repo filter (from parent) -->
        <span v-if="repoFilter" class="text-slate-500">repo: {{ repoFilter }}</span>
        <span v-if="hostFilter" class="text-slate-500">host: {{ hostFilter }}</span>
        <button @click="emit('close')" class="text-slate-500 hover:text-slate-200 text-sm px-1 ml-2">✕</button>
      </div>
    </div>

    <div v-if="loading" class="flex-1 flex items-center justify-center text-slate-500 text-sm">Loading costs...</div>

    <div v-else-if="costs.length === 0" class="flex-1 flex items-center justify-center text-slate-500 text-sm">
      No cost data yet. Ensure ccusage is installed and the daemon is running.
    </div>

    <div v-else class="flex-1 overflow-y-auto p-4 space-y-6">
      <!-- Summary cards -->
      <div class="grid grid-cols-3 gap-4">
        <div class="bg-slate-800 rounded-lg p-4 border border-slate-700">
          <div class="text-xs text-slate-500 mb-1">Total Cost</div>
          <div class="text-2xl font-bold text-slate-100">${{ totalCost.toFixed(2) }}</div>
        </div>
        <div class="bg-slate-800 rounded-lg p-4 border border-slate-700">
          <div class="text-xs text-slate-500 mb-1">Total Tokens</div>
          <div class="text-2xl font-bold text-slate-100">{{ formatTokens(totalTokens) }}</div>
        </div>
        <div class="bg-slate-800 rounded-lg p-4 border border-slate-700">
          <div class="text-xs text-slate-500 mb-1">Days</div>
          <div class="text-2xl font-bold text-slate-100">{{ uniqueDates.length }}</div>
        </div>
      </div>

      <!-- By model breakdown -->
      <div class="bg-slate-800 rounded-lg p-4 border border-slate-700">
        <h3 class="text-xs font-semibold text-slate-400 mb-3">By Model</h3>
        <div class="space-y-2">
          <div v-for="m in modelBreakdown" :key="m.model" class="flex items-center gap-3">
            <span class="text-xs text-slate-300 font-mono w-32 truncate">{{ m.model }}</span>
            <div class="flex-1 h-4 bg-slate-700 rounded overflow-hidden">
              <div
                class="h-full rounded"
                :class="modelColor(m.model)"
                :style="{ width: `${(m.cost / maxModelCost) * 100}%` }"
              />
            </div>
            <span class="text-xs text-slate-400 w-20 text-right">${{ m.cost.toFixed(2) }}</span>
            <span class="text-xs text-slate-600 w-24 text-right">{{ formatTokens(m.tokens) }}</span>
          </div>
        </div>
      </div>

      <!-- Daily chart -->
      <div class="bg-slate-800 rounded-lg p-4 border border-slate-700">
        <h3 class="text-xs font-semibold text-slate-400 mb-3">Daily Cost</h3>
        <div class="flex items-end gap-1" style="height: 120px">
          <div
            v-for="d in dailyBreakdown"
            :key="d.date"
            class="flex-1 flex flex-col justify-end items-center gap-0"
            :title="`${d.date}: $${d.cost.toFixed(2)}`"
          >
            <!-- Stacked bars per model -->
            <template v-for="(seg, i) in d.segments" :key="i">
              <div
                :class="modelColor(seg.model)"
                :style="{ height: `${(seg.cost / maxDailyCost) * 100}px`, minHeight: seg.cost > 0 ? '1px' : '0' }"
                class="w-full rounded-t-sm"
              />
            </template>
            <span class="text-[8px] text-slate-600 mt-1 rotate-45 origin-left">{{ d.date.slice(5) }}</span>
          </div>
        </div>
      </div>

      <!-- By container -->
      <div class="bg-slate-800 rounded-lg p-4 border border-slate-700">
        <h3 class="text-xs font-semibold text-slate-400 mb-3">By Container</h3>
        <div class="space-y-2">
          <div v-for="c in containerBreakdown" :key="c.containerId" class="flex items-center gap-3">
            <span class="text-xs text-slate-300 font-mono w-48 truncate" :title="c.containerId">{{ c.label }}</span>
            <div class="flex-1 h-4 bg-slate-700 rounded overflow-hidden">
              <div
                class="h-full bg-blue-600 rounded"
                :style="{ width: `${(c.cost / maxContainerCost) * 100}%` }"
              />
            </div>
            <span class="text-xs text-slate-400 w-20 text-right">${{ c.cost.toFixed(2) }}</span>
          </div>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { ref, computed, onMounted } from 'vue'
import { API_BASE } from '../config'

const props = defineProps<{
  repoFilter: string
  hostFilter: string
}>()

const emit = defineEmits<{ close: [] }>()

interface CostRow {
  container_id: string
  source_repo: string
  machine_hostname: string
  date: string
  model: string
  agent: string
  input_tokens: number
  output_tokens: number
  cache_read_tokens: number
  cache_creation_tokens: number
  total_cost_usd: number
}

const costs = ref<CostRow[]>([])
const loading = ref(false)
const dateRange = ref('30d')
const modelFilter = ref('')

function dateFrom(): string {
  if (dateRange.value === 'all') return ''
  const days = parseInt(dateRange.value)
  const d = new Date()
  d.setDate(d.getDate() - days)
  return d.toISOString().slice(0, 10)
}

async function reload() {
  loading.value = true
  try {
    const params = new URLSearchParams()
    const from = dateFrom()
    if (from) params.set('from', from)
    if (modelFilter.value) params.set('model', modelFilter.value)
    if (props.repoFilter) params.set('repo', props.repoFilter)
    if (props.hostFilter) params.set('host', props.hostFilter)
    const res = await fetch(`${API_BASE}/dashboard/costs?${params}`)
    if (res.ok) costs.value = await res.json()
  } finally {
    loading.value = false
  }
}

const totalCost = computed(() => costs.value.reduce((s, c) => s + c.total_cost_usd, 0))
const totalTokens = computed(() => costs.value.reduce((s, c) => s + c.input_tokens + c.output_tokens, 0))
const uniqueDates = computed(() => [...new Set(costs.value.map(c => c.date))].sort())

const availableModels = computed(() => [...new Set(costs.value.map(c => c.model))].sort())

const modelBreakdown = computed(() => {
  const map = new Map<string, { cost: number; tokens: number }>()
  for (const c of costs.value) {
    const e = map.get(c.model) ?? { cost: 0, tokens: 0 }
    e.cost += c.total_cost_usd
    e.tokens += c.input_tokens + c.output_tokens
    map.set(c.model, e)
  }
  return [...map].map(([model, v]) => ({ model, ...v })).sort((a, b) => b.cost - a.cost)
})

const maxModelCost = computed(() => Math.max(...modelBreakdown.value.map(m => m.cost), 1))

const dailyBreakdown = computed(() => {
  const models = availableModels.value
  const byDate = new Map<string, Map<string, number>>()
  for (const c of costs.value) {
    if (!byDate.has(c.date)) byDate.set(c.date, new Map())
    const dm = byDate.get(c.date)!
    dm.set(c.model, (dm.get(c.model) ?? 0) + c.total_cost_usd)
  }
  return uniqueDates.value.map(date => {
    const dm = byDate.get(date) ?? new Map()
    const cost = [...dm.values()].reduce((s, v) => s + v, 0)
    const segments = models.map(model => ({ model, cost: dm.get(model) ?? 0 }))
    return { date, cost, segments }
  })
})

const maxDailyCost = computed(() => Math.max(...dailyBreakdown.value.map(d => d.cost), 1))

const containerBreakdown = computed(() => {
  const map = new Map<string, { cost: number; repo: string; host: string }>()
  for (const c of costs.value) {
    const e = map.get(c.container_id) ?? { cost: 0, repo: c.source_repo, host: c.machine_hostname }
    e.cost += c.total_cost_usd
    map.set(c.container_id, e)
  }
  return [...map].map(([containerId, v]) => {
    const shortId = containerId.includes(':') ? containerId.split(':').pop()!.slice(0, 8) : containerId
    return { containerId, label: `${v.repo}:${shortId}`, ...v }
  }).sort((a, b) => b.cost - a.cost)
})

const maxContainerCost = computed(() => Math.max(...containerBreakdown.value.map(c => c.cost), 1))

function modelColor(model: string): string {
  if (model.includes('opus')) return 'bg-purple-600'
  if (model.includes('sonnet')) return 'bg-blue-600'
  if (model.includes('haiku')) return 'bg-teal-600'
  if (model.includes('glm')) return 'bg-green-600'
  return 'bg-slate-500'
}

function formatTokens(n: number): string {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}M`
  if (n >= 1_000) return `${(n / 1_000).toFixed(0)}K`
  return String(n)
}

onMounted(reload)
</script>
