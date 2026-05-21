<template>
  <div
    class="mt-2"
    @dragover="onPanelDragOver"
    @dragleave="onPanelDragLeave"
    @drop="onPanelDrop"
    :class="crossDropHighlight ? 'outline outline-2 outline-blue-500/60 rounded-lg' : ''"
  >
    <!-- Cross-container drop hint -->
    <div
      v-if="crossDropHighlight"
      class="text-xs text-blue-300 bg-blue-900/30 border border-blue-600/50 rounded px-2 py-1 mb-1 text-center pointer-events-none"
    >Drop to copy/move here</div>

    <!-- Header -->
    <button
      @click="toggleOpen()"
      class="flex items-center gap-2 text-xs text-slate-400 hover:text-slate-200 font-semibold w-full text-left py-1"
    >
      <span>{{ open ? '▾' : '▸' }}</span>
      <span>Plan Queue</span>
      <span class="text-slate-500">({{ pendingCount }} pending{{ autoQueueCount > 0 ? `, ${autoQueueCount} queued` : '' }}{{ underwayCount > 0 ? `, ${underwayCount} underway` : '' }}{{ awaitingCommitCount > 0 ? `, ${awaitingCommitCount} awaiting commit` : '' }}{{ awaitingPlanCount > 0 ? `, ${awaitingPlanCount} awaiting plan` : '' }}{{ doneCount > 0 ? `, ${doneCount} done` : '' }})</span>
    </button>

    <div v-if="open" class="mt-1 bg-slate-900/50 rounded-lg border border-slate-700 p-2">
      <!-- Offline notice -->
      <div v-if="!connected" class="text-xs text-slate-500 italic mb-2">
        Container offline — queue shown from last heartbeat; edits will fail.
      </div>

      <!-- Auto-queue notice -->
      <div v-if="autoQueueCount > 0" class="text-xs text-cyan-400 mb-2 flex items-center gap-1">
        <span>⏱</span>
        <span>{{ autoQueueCount }} task{{ autoQueueCount > 1 ? 's' : '' }} queued for auto-run</span>
        <span v-if="multipleAutoWarning" class="text-yellow-400 ml-1">⚠ multiple auto-queue sessions may be running</span>
      </div>

      <!-- Awaiting-commit notice -->
      <div v-if="awaitingCommitCount > 0" class="text-xs text-purple-400 mb-2 flex items-center gap-1">
        <span>💾</span>
        <span>{{ awaitingCommitCount }} task{{ awaitingCommitCount > 1 ? 's' : '' }} awaiting commit — commit staged changes to continue</span>
      </div>

      <!-- Awaiting-plan notice -->
      <div v-if="awaitingPlanCount > 0" class="text-xs text-teal-400 mb-2 flex items-center gap-1">
        <span>📋</span>
        <span>{{ awaitingPlanCount }} task{{ awaitingPlanCount > 1 ? 's' : '' }} awaiting plan review — add the generated plan to the queue to continue</span>
      </div>

      <!-- Auto-test pending prompt -->
      <div v-if="autoTestPending" class="mb-2 rounded border border-red-700 bg-red-950/40 p-2">
        <div class="flex items-center gap-2 mb-1">
          <span class="text-red-400 text-xs font-semibold">⚠ Auto-test failed</span>
          <span class="text-red-500 text-xs font-mono">(exit {{ autoTestPending.exit_code }})</span>
        </div>
        <div class="text-xs text-slate-400 font-mono mb-1">$ {{ autoTestPending.command }}</div>
        <pre class="text-xs text-red-300 font-mono whitespace-pre-wrap break-words overflow-y-auto max-h-32 mb-2 bg-black/30 rounded p-1">{{ autoTestPending.output }}</pre>
        <div class="flex gap-2">
          <button
            @click="respondAutoTest('continue')"
            :disabled="respondingAutoTest"
            class="text-xs px-2 py-1 rounded bg-green-800 hover:bg-green-700 text-green-200 disabled:opacity-50"
          >Continue auto-queue</button>
          <button
            @click="respondAutoTest('abort')"
            :disabled="respondingAutoTest"
            class="text-xs px-2 py-1 rounded bg-red-800 hover:bg-red-700 text-red-200 disabled:opacity-50"
          >Abort</button>
        </div>
      </div>

      <!-- Status / review / type filters (single wrapping row) -->
      <div class="flex items-center gap-1 mb-1 flex-wrap">
        <span class="text-xs text-slate-600 shrink-0">status:</span>
        <button
          v-for="f in statusFilters"
          :key="f.status"
          @click.exact="toggleFilterExclusive(f.status)"
          @click.ctrl.exact="toggleFilter(f.status)"
          @click.meta.exact="toggleFilter(f.status)"
          @click.alt.exact="toggleFilterInverted(f.status)"
          :title="`${f.label} (${f.count}) — click to filter, Ctrl/Cmd+click to multi-select, Alt+click to invert`"
          class="flex items-center gap-0.5 px-1.5 py-0.5 rounded text-xs transition-all"
          :class="activeFilters.size === 0 || activeFilters.has(f.status)
            ? [f.activeClass, 'opacity-100']
            : 'bg-slate-800 text-slate-600 opacity-50'"
        >
          <span>{{ f.icon }}</span>
          <span>{{ f.count }}</span>
        </button>
        <button
          v-if="activeFilters.size > 0"
          @click="activeFilters.clear()"
          class="px-1.5 py-0.5 rounded text-xs bg-slate-700 text-slate-400 hover:text-slate-200 hover:bg-slate-600"
          title="Clear work status filter"
        >✕</button>
        <template v-if="reviewFilterVisible">
          <span class="text-slate-700 select-none shrink-0">|</span>
          <span class="text-xs text-slate-600 shrink-0">review:</span>
          <button
            v-for="f in reviewFilters"
            :key="f.status"
            @click.exact="toggleReviewFilterExclusive(f.status)"
            @click.ctrl.exact="toggleReviewFilter(f.status)"
            @click.meta.exact="toggleReviewFilter(f.status)"
            @click.alt.exact="toggleReviewFilterInverted(f.status)"
            :title="`${f.label} (${f.count}) — click to filter, Ctrl/Cmd+click to multi-select, Alt+click to invert`"
            class="flex items-center gap-0.5 px-1.5 py-0.5 rounded text-xs transition-all"
            :class="activeReviewFilters.size === 0 || activeReviewFilters.has(f.status)
              ? [f.activeClass, 'opacity-100']
              : 'bg-slate-800 text-slate-600 opacity-50'"
          >
            <span>{{ f.icon }}</span>
            <span>{{ f.count }}</span>
          </button>
          <button
            v-if="activeReviewFilters.size > 0"
            @click="activeReviewFilters.clear()"
            class="px-1.5 py-0.5 rounded text-xs bg-slate-700 text-slate-400 hover:text-slate-200 hover:bg-slate-600"
            title="Clear review status filter"
          >✕</button>
        </template>
        <template v-if="typeFilters.some(f => f.count > 0)">
          <span class="text-slate-700 select-none shrink-0">|</span>
          <span class="text-xs text-slate-600 shrink-0">type:</span>
          <button
            v-for="f in typeFilters.filter(f => f.count > 0)"
            :key="f.type"
            @click.exact="toggleTypeFilterExclusive(f.type)"
            @click.ctrl.exact="toggleTypeFilter(f.type)"
            @click.meta.exact="toggleTypeFilter(f.type)"
            @click.alt.exact="toggleTypeFilterInverted(f.type)"
            :title="`${f.label} (${f.count}) — click to filter, Ctrl/Cmd+click to multi-select, Alt+click to invert`"
            class="flex items-center gap-0.5 px-1.5 py-0.5 rounded text-xs transition-all"
            :class="activeTypeFilters.size === 0 || activeTypeFilters.has(f.type)
              ? [f.activeClass, 'opacity-100']
              : 'bg-slate-800 text-slate-600 opacity-50'"
          >
            <span>{{ f.icon }}</span>
            <span>{{ f.count }}</span>
          </button>
          <button
            v-if="activeTypeFilters.size > 0"
            @click="activeTypeFilters.clear()"
            class="px-1.5 py-0.5 rounded text-xs bg-slate-700 text-slate-400 hover:text-slate-200 hover:bg-slate-600"
            title="Clear type filter"
          >✕</button>
        </template>
      </div>

      <!-- Sort / time filter row -->
      <div class="flex items-center gap-1 mb-1 flex-wrap text-xs">
        <span class="text-slate-600 shrink-0">sort:</span>
        <button
          v-for="s in SORT_DEFS"
          :key="s.mode"
          @click="sortMode = s.mode"
          class="px-1.5 py-0.5 rounded transition-all"
          :class="sortMode === s.mode ? 'bg-slate-600 text-slate-200' : 'bg-slate-800 text-slate-500 hover:text-slate-300'"
          :title="s.label"
        >{{ s.icon }}</button>
        <span class="text-slate-700 select-none shrink-0">|</span>
        <span class="text-slate-600 shrink-0">time:</span>
        <button
          v-for="t in TIME_FILTER_DEFS"
          :key="t.value"
          @click="timeFilter = timeFilter === t.value ? '' : t.value"
          class="px-1.5 py-0.5 rounded transition-all"
          :class="timeFilter === t.value ? 'bg-amber-900/60 text-amber-300' : 'bg-slate-800 text-slate-500 hover:text-slate-300'"
        >{{ t.label }}</button>
        <button
          v-if="timeFilter"
          @click="timeFilter = ''"
          class="px-1.5 py-0.5 rounded text-xs bg-slate-700 text-slate-400 hover:text-slate-200 hover:bg-slate-600"
        >✕</button>
      </div>

      <!-- Task list: flat DFS-ordered list supporting unlimited nesting levels -->
      <div v-if="visibleTasksFlat.length > 0" ref="taskListRef">
        <template v-for="item in visibleTasksFlat" :key="item.task.id">
          <PlanqTaskRow
            :task="item.task"
            :position="item.position"
            :container-id="containerId"
            :all-tasks="tasks"
            :dimmed="item.dimmed"
            :highlighted="highlightedTaskId === item.task.id"
            :nest-level="item.depth"
            :link-type="item.depth > 0 ? item.task.link_type : undefined"
            :plans-files-list="props.plansFilesList"
            @edit-file="editingFile = item.task"
            @set-status="(t, s) => setStatus(t, s)"
            @delete="deleteTask(item.task.id)"
            @update-desc="(id, desc) => updateDesc(id, desc)"
            @set-commit-mode="(t, m) => setCommitMode(t, m)"
            @add-plan="addPlanFromMakePlan"
            @archive="archiveTask(item.task.id)"
            @set-review-status="(t, s) => setReviewStatus(t, s)"
            @add-subtask="addingSubtaskTo = item.task"
            @dragstart="onTaskDragStart(item.task.id)"
            @dragend="onTaskDragEnd"
            @drop="dropOn(item.task.id)"
            @open-session="sid => emit('open-history', sid)"
            @open-git-view="(repo, hash) => emit('open-git-view', repo, hash)"
            @navigate-to-parent="navigateToTask"
            @copy-to-container="t => openMoveDialog(t, 'copy')"
            @move-to-container="t => openMoveDialog(t, 'move')"
          />
        </template>
      </div>
      <div v-else-if="tasks.length > 0 && hasActiveFilters" class="text-xs text-slate-500 italic py-1">No tasks match filter.</div>
      <div v-else class="text-xs text-slate-500 italic py-1">No tasks queued.</div>

      <!-- Add buttons -->
      <div class="flex items-center gap-2 mt-2 pt-2 border-t border-slate-700 flex-wrap">
        <button
          @click="showAddDialog = true"
          class="text-xs px-2 py-1 rounded bg-slate-700 hover:bg-slate-600 text-slate-300"
        >+ Add task</button>
        <button
          v-if="doneCount > 0"
          @click="archiveDone"
          class="text-xs px-2 py-1 rounded bg-slate-700 hover:bg-slate-600 text-slate-400"
          title="Move done tasks to archive"
        >Archive done</button>
        <div class="flex items-center gap-1 ml-auto">
          <span class="text-xs text-slate-600" title="Default commit mode for new tasks">after:</span>
          <button
            v-for="opt in [
              { value: 'none', label: '—' },
              { value: 'auto-commit', label: 'auto' },
              { value: 'stage-commit', label: 'stage' },
              { value: 'manual-commit', label: 'manual' },
            ]"
            :key="opt.value"
            type="button"
            :disabled="savingCommitMode"
            @click="setDefaultCommitMode(opt.value as any)"
            class="text-xs px-1.5 py-0.5 rounded border transition-colors disabled:opacity-50"
            :class="defaultCommitMode === opt.value
              ? opt.value === 'none' ? 'border-slate-500 bg-slate-600 text-slate-200'
                : opt.value === 'auto-commit' ? 'border-green-600 bg-green-900/50 text-green-300'
                : opt.value === 'stage-commit' ? 'border-blue-600 bg-blue-900/50 text-blue-300'
                : 'border-orange-600 bg-orange-900/50 text-orange-300'
              : 'border-slate-700 bg-transparent text-slate-500 hover:bg-slate-700'"
            :title="`Default commit mode: ${opt.value}`"
          >{{ opt.label }}</button>
        </div>
      </div>

      <!-- Archive section -->
      <div class="mt-2 pt-2 border-t border-slate-700/50">
        <button
          @click="toggleArchive"
          class="flex items-center gap-1 text-xs text-slate-500 hover:text-slate-400 w-full text-left py-0.5"
        >
          <span>{{ archiveOpen ? '▾' : '▸' }}</span>
          <span>Archive</span>
        </button>
        <div v-if="archiveOpen" class="mt-1">
          <div v-if="archiveLoading" class="text-xs text-slate-500 italic py-1">Loading…</div>
          <div v-else-if="archiveTasks.length === 0" class="text-xs text-slate-500 italic py-1">No archived tasks.</div>
          <div v-else>
            <div
              v-for="(item, i) in archiveTasks"
              :key="i"
              class="flex items-center gap-2 py-1 px-2 rounded text-xs opacity-60"
              :style="item.depth ? { paddingLeft: `${(item.depth * 12) + 8}px` } : {}"
            >
              <span class="text-green-600">✓</span>
              <span
                class="px-1 py-0.5 rounded font-mono shrink-0"
                :class="archiveBadgeClass(item.task_type)"
              >{{ item.task_type }}</span>
              <button
                v-if="item.filename"
                @click="archiveViewingFile = item.filename"
                class="text-slate-400 truncate font-mono hover:text-slate-200 hover:underline text-left min-w-0"
              >{{ item.filename }}</button>
              <span v-else class="text-slate-400 truncate font-mono">{{ item.description }}</span>
              <button
                v-if="item.task_type === 'investigate' && item.filename"
                @click="archiveViewingFile = item.filename.replace(/^investigate-/, 'feedback-')"
                class="shrink-0 text-indigo-500 hover:text-indigo-300 text-xs"
                title="View investigation feedback"
              >feedback</button>
              <button
                v-if="!item.depth"
                @click="unarchiveTask(i)"
                class="shrink-0 text-slate-500 hover:text-amber-400 text-xs ml-auto"
                title="Restore to queue"
              >↩</button>
            </div>
          </div>
        </div>
      </div>
    </div>

    <!-- Dialogs -->
    <AddTaskDialog
      v-if="showAddDialog"
      :container-id="containerId"
      :all-tasks="tasks"
      @close="showAddDialog = false"
      @add="(type, fn, desc, createFile, commitMode, planDisposition, autoQueuePlan, parentTaskId, linkType, subtasks, autoQueue) => addTask(type, fn, desc, createFile, commitMode, planDisposition, autoQueuePlan, parentTaskId, linkType, subtasks, autoQueue)"
    />
    <AddTaskDialog
      v-if="addingSubtaskTo"
      :container-id="containerId"
      :all-tasks="tasks"
      :parent-task="addingSubtaskTo"
      @close="addingSubtaskTo = null"
      @add="(type, fn, desc, createFile, commitMode, planDisposition, autoQueuePlan, parentTaskId, linkType, subtasks, autoQueue) => addTask(type, fn, desc, createFile, commitMode, planDisposition, autoQueuePlan, parentTaskId, linkType, subtasks, autoQueue)"
    />

    <PlanqFileEditor
      v-if="editingFile"
      :container-id="containerId"
      :filename="editingFile.filename!"
      @close="editingFile = null"
      @saved="clearCached(editingFile!.filename!); editingFile = null"
    />
    <PlanqFileEditor
      v-if="archiveViewingFile"
      :container-id="containerId"
      :filename="archiveViewingFile"
      @close="archiveViewingFile = null"
      @saved="archiveViewingFile = null"
    />

    <MoveTaskDialog
      v-if="moveDialogTask"
      :task="moveDialogTask"
      :container-id="moveDialogSourceContainerId"
      :all-tasks="tasks"
      :initial-mode="moveDialogMode"
      :initial-target-container-id="moveDialogTargetContainerId"
      @close="moveDialogTask = null"
      @done="onMoveDialogDone"
    />
  </div>
</template>

<script setup lang="ts">
import { ref, computed, reactive, watch, onMounted, nextTick } from 'vue'
import { usePlanq } from '../composables/usePlanq'
import { useContainers } from '../composables/useContainers'
import { usePlanqPanelState } from '../composables/usePanelState'
import { useExpandedTasks } from '../composables/useExpandedTasks'
import { useCrossContainerDrag } from '../composables/useCrossContainerDrag'
import PlanqTaskRow from './PlanqTaskRow.vue'
import AddTaskDialog from './AddTaskDialog.vue'
import PlanqFileEditor from './PlanqFileEditor.vue'
import MoveTaskDialog from './MoveTaskDialog.vue'
import type { PlanqTask, PlanqItem, AutoTestPending, ReviewStatus } from '../types'
import type { SubtaskEntry } from './AddTaskDialog.vue'

const props = defineProps<{
  containerId: string
  tasks: PlanqTask[]
  connected: boolean
  autoTestPending?: AutoTestPending | null
  initialReviewFilter?: string
  plansFilesList?: string[]
}>()

const emit = defineEmits<{
  'tasks-changed': []
  'open-history': [sessionId: string]
  'open-git-view': [repo: string, hash: string]
}>()

const { addTask: apiAdd, updateTask: apiUpdate, deleteTask: apiDelete, reorderTasks: apiReorder, fetchArchive: apiFetchArchive, archiveTask: apiArchiveTask, unarchiveTask: apiUnarchiveTask, archiveDone: apiArchiveDone, respondToAutoTest: apiRespondAutoTest, getSettings: apiGetSettings, updateSettings: apiUpdateSettings } = usePlanq()
const { updatePlanqTaskOptimistic } = useContainers()
const { clearCached } = useExpandedTasks()
const { dragTask: crossDragTask, dragContainerId: crossDragContainerId, startDrag: startCrossDrag, endDrag: endCrossDrag } = useCrossContainerDrag()

const { open, toggle: toggleOpen } = usePlanqPanelState(props.containerId)
const showAddDialog = ref(false)
const addingSubtaskTo = ref<PlanqTask | null>(null)
const editingFile = ref<PlanqTask | null>(null)
const archiveViewingFile = ref<string | null>(null)
const dragFrom = ref<number | null>(null)

// Sort mode and time filter
type SortMode = 'standard' | 'done-asc' | 'done-desc'
type TimeFilter = '' | '5min' | '15min' | '30min' | '1h' | '2h' | 'today'
const sortMode = ref<SortMode>('standard')
const timeFilter = ref<TimeFilter>('')
const highlightedTaskId = ref<number | null>(null)
const taskListRef = ref<HTMLElement | null>(null)

const SORT_DEFS: Array<{ mode: SortMode; icon: string; label: string }> = [
  { mode: 'standard',  icon: '↕ queue',   label: 'Standard queue order' },
  { mode: 'done-asc',  icon: '↑ time',    label: 'Sort by done time (oldest first)' },
  { mode: 'done-desc', icon: '↓ time',    label: 'Sort by done time (newest first)' },
]
const TIME_FILTER_DEFS: Array<{ value: TimeFilter; label: string }> = [
  { value: '5min',  label: '5m' },
  { value: '15min', label: '15m' },
  { value: '30min', label: '30m' },
  { value: '1h',    label: '1h' },
  { value: '2h',    label: '2h' },
  { value: 'today', label: 'today' },
]

const timeCutoff = computed((): number | null => {
  if (!timeFilter.value) return null
  const now = Date.now()
  switch (timeFilter.value) {
    case '5min':  return now - 5 * 60 * 1000
    case '15min': return now - 15 * 60 * 1000
    case '30min': return now - 30 * 60 * 1000
    case '1h':    return now - 60 * 60 * 1000
    case '2h':    return now - 2 * 60 * 60 * 1000
    case 'today': { const d = new Date(); d.setHours(0,0,0,0); return d.getTime() }
    default: return null
  }
})

function navigateToTask(taskId: number) {
  highlightedTaskId.value = taskId
  nextTick(() => {
    const el = taskListRef.value?.querySelector(`[data-task-id="${taskId}"]`) as HTMLElement | null
    el?.scrollIntoView({ behavior: 'smooth', block: 'nearest' })
    setTimeout(() => { if (highlightedTaskId.value === taskId) highlightedTaskId.value = null }, 2000)
  })
}

// Move/copy dialog
const moveDialogTask = ref<PlanqTask | null>(null)
const moveDialogMode = ref<'copy' | 'move'>('copy')
const moveDialogSourceContainerId = ref(props.containerId)
const moveDialogTargetContainerId = ref<string | undefined>(undefined)
const crossDropHighlight = ref(false)

function openMoveDialog(task: PlanqTask, mode: 'copy' | 'move', targetContainerId?: string) {
  moveDialogTask.value = task
  moveDialogMode.value = mode
  // For drag: task is from another container; source is that container, target is this panel
  moveDialogSourceContainerId.value = targetContainerId ? task.container_id : props.containerId
  moveDialogTargetContainerId.value = targetContainerId
}

function onMoveDialogDone() {
  emit('tasks-changed')
}

// Cross-container drag: track dragstart/dragend globally
function onTaskDragStart(taskId: number) {
  dragFrom.value = taskId
  const task = props.tasks.find(t => t.id === taskId)
  if (task) startCrossDrag(task, props.containerId)
}

function onTaskDragEnd() {
  endCrossDrag()
}

// Cross-container drop zone: when something dragged from another container is dropped here
function onPanelDragOver(e: DragEvent) {
  if (crossDragContainerId.value && crossDragContainerId.value !== props.containerId) {
    e.preventDefault()
    crossDropHighlight.value = true
  }
}

function onPanelDragLeave() {
  crossDropHighlight.value = false
}

function onPanelDrop(e: DragEvent) {
  crossDropHighlight.value = false
  if (!crossDragTask.value || crossDragContainerId.value === props.containerId) return
  e.preventDefault()
  e.stopPropagation()
  openMoveDialog(crossDragTask.value, 'copy', props.containerId)
  endCrossDrag()
}

// Default commit mode setting
const defaultCommitMode = ref<'none' | 'auto-commit' | 'stage-commit' | 'manual-commit'>('none')
const savingCommitMode = ref(false)

onMounted(async () => {
  const settings = await apiGetSettings(props.containerId)
  const v = settings['DEFAULT_COMMIT_MODE']
  if (v === 'auto-commit' || v === 'stage-commit' || v === 'manual-commit') {
    defaultCommitMode.value = v
  }
})

async function setDefaultCommitMode(mode: 'none' | 'auto-commit' | 'stage-commit' | 'manual-commit') {
  defaultCommitMode.value = mode
  savingCommitMode.value = true
  await apiUpdateSettings(props.containerId, { DEFAULT_COMMIT_MODE: mode })
  savingCommitMode.value = false
}

// Archive
const archiveOpen = ref(false)
const archiveTasks = ref<PlanqItem[]>([])
const archiveLoading = ref(false)

async function toggleArchive() {
  archiveOpen.value = !archiveOpen.value
  if (archiveOpen.value) {
    archiveLoading.value = true
    archiveTasks.value = await apiFetchArchive(props.containerId)
    archiveLoading.value = false
  }
}

// Work status filters
const activeFilters = reactive(new Set<string>())

function toggleFilter(status: string) {
  if (activeFilters.has(status)) activeFilters.delete(status)
  else activeFilters.add(status)
}

function toggleFilterExclusive(status: string) {
  if (activeFilters.size === 1 && activeFilters.has(status)) {
    activeFilters.clear()
  } else {
    activeFilters.clear()
    activeFilters.add(status)
  }
}

function toggleFilterInverted(status: string) {
  if (activeFilters.has(status)) {
    activeFilters.delete(status)
  } else {
    activeFilters.clear()
    for (const f of STATUS_FILTER_DEFS) { if (f.status !== status) activeFilters.add(f.status) }
  }
}

// Review status filters
const activeReviewFilters = reactive(new Set<string>(
  props.initialReviewFilter ? [props.initialReviewFilter] : []
))

// When the parent changes the filter (e.g. clicking a different badge for the
// same already-open container), update the active set so the filter takes effect.
watch(() => props.initialReviewFilter, (newFilter) => {
  if (newFilter) {
    activeReviewFilters.clear()
    activeReviewFilters.add(newFilter)
  }
})

function toggleReviewFilter(status: string) {
  if (activeReviewFilters.has(status)) activeReviewFilters.delete(status)
  else activeReviewFilters.add(status)
}

function toggleReviewFilterExclusive(status: string) {
  if (activeReviewFilters.size === 1 && activeReviewFilters.has(status)) {
    activeReviewFilters.clear()
  } else {
    activeReviewFilters.clear()
    activeReviewFilters.add(status)
  }
}

function toggleReviewFilterInverted(status: string) {
  if (activeReviewFilters.has(status)) {
    activeReviewFilters.delete(status)
  } else {
    activeReviewFilters.clear()
    for (const f of REVIEW_STATUS_DEFS) { if (f.status !== status) activeReviewFilters.add(f.status) }
  }
}

// Map from parent task ID to its child tasks (in position order)
const taskChildren = computed(() => {
  const map = new Map<number, typeof props.tasks>()
  for (const t of props.tasks) {
    if (t.parent_task_id != null) {
      if (!map.has(t.parent_task_id)) map.set(t.parent_task_id, [])
      map.get(t.parent_task_id)!.push(t)
    }
  }
  return map
})

// IDs of tasks that are children of another task (should not appear at top level)
const childTaskIds = computed(() => new Set(props.tasks.filter(t => t.parent_task_id != null).map(t => t.id)))

// Deferred tasks always appear at the bottom; child tasks are excluded from top level
const sortedTasks = computed(() => {
  const topLevel = props.tasks.filter(t => !childTaskIds.value.has(t.id))
  const nonDeferred = topLevel.filter(t => t.status !== 'deferred')
  const deferred = topLevel.filter(t => t.status === 'deferred')
  return [...nonDeferred, ...deferred]
})

const hasActiveFilters = computed(() =>
  activeFilters.size > 0 || activeTypeFilters.size > 0 || activeReviewFilters.size > 0 || !!timeFilter.value
)

function taskMatchesFilters(t: PlanqTask): boolean {
  if (activeFilters.size > 0 && !activeFilters.has(t.status)) return false
  if (activeTypeFilters.size > 0 && !activeTypeFilters.has(t.task_type)) return false
  if (activeReviewFilters.size > 0 && !activeReviewFilters.has(t.review_status ?? 'none')) return false
  if (timeCutoff.value != null && (t.done_at == null || t.done_at < timeCutoff.value)) return false
  return true
}

function anyDescendantMatchesFilters(taskId: number): boolean {
  const children = taskChildren.value.get(taskId) ?? []
  return children.some(c => taskMatchesFilters(c) || anyDescendantMatchesFilters(c.id))
}


// Pre-compute dotted positions for ALL tasks in the unfiltered tree so filtering
// never changes task numbers (consistent with planq.sh display).
const taskPositions = computed(() => {
  const positions = new Map<number, string>()
  function dfs(tasks: PlanqTask[], prefix: string) {
    tasks.forEach((task, idx) => {
      const pos = `${prefix}${idx + 1}`
      positions.set(task.id, pos)
      const children = taskChildren.value.get(task.id) ?? []
      if (children.length > 0) dfs(children, `${pos}.`)
    })
  }
  dfs(sortedTasks.value, '')
  return positions
})

// Flat DFS-ordered list of all visible tasks (all nesting levels) with depth, position, dimmed.
const visibleTasksFlat = computed((): { task: PlanqTask; depth: number; position: string; dimmed: boolean }[] => {
  // When sorted by time, flatten all tasks independently (no tree grouping), sorted by done_at
  if (sortMode.value !== 'standard') {
    const all = props.tasks.filter(t => taskMatchesFilters(t))
    all.sort((a, b) => {
      const da = a.done_at ?? 0
      const db = b.done_at ?? 0
      return sortMode.value === 'done-asc' ? da - db : db - da
    })
    return all.map(task => ({
      task,
      depth: 0,
      position: taskPositions.value.get(task.id) ?? '?',
      dimmed: false,
    }))
  }

  const result: { task: PlanqTask; depth: number; position: string; dimmed: boolean }[] = []

  function visit(task: PlanqTask, depth: number) {
    const direct = !hasActiveFilters.value || taskMatchesFilters(task)
    const childMatch = anyDescendantMatchesFilters(task.id)
    if (!direct && !childMatch) return

    result.push({
      task,
      depth,
      position: taskPositions.value.get(task.id) ?? '?',
      dimmed: hasActiveFilters.value && !direct,
    })

    const children = taskChildren.value.get(task.id) ?? []
    for (const child of children) {
      visit(child, depth + 1)
    }
  }

  for (const task of sortedTasks.value) {
    visit(task, 0)
  }

  return result
})

const REVIEW_STATUS_DEFS: Array<{ status: string; icon: string; label: string; activeClass: string }> = [
  { status: 'ready',          icon: '🔵', label: 'Ready',          activeClass: 'bg-blue-900/60 text-blue-300' },
  { status: 'testing',        icon: '🧪', label: 'Testing',        activeClass: 'bg-yellow-900/60 text-yellow-300' },
  { status: 'passed',         icon: '🟢', label: 'Passed',         activeClass: 'bg-green-900/60 text-green-300' },
  { status: 'has-issues',     icon: '🔴', label: 'Has Issues',     activeClass: 'bg-red-900/60 text-red-300' },
  { status: 'fix-scheduled',  icon: '🔧', label: 'Fix Scheduled',  activeClass: 'bg-orange-900/60 text-orange-300' },
  { status: 'follow-up',      icon: '🔄', label: 'Follow-up',      activeClass: 'bg-purple-900/60 text-purple-300' },
  { status: 'revert-scheduled', icon: '⏪', label: 'Revert Sched.', activeClass: 'bg-red-950/80 text-red-400' },
  { status: 'ready-for-merge', icon: '🚀', label: 'Ready to Merge', activeClass: 'bg-teal-900/60 text-teal-300' },
  { status: 'merged',         icon: '🏁', label: 'Merged',         activeClass: 'bg-green-950/80 text-green-500' },
  { status: 'cancelled',      icon: '🚫', label: 'Cancelled',      activeClass: 'bg-slate-700 text-slate-400' },
  { status: 'retry-later',    icon: '⏸️',  label: 'Retry Later',   activeClass: 'bg-yellow-950/80 text-yellow-500' },
]

const reviewFilters = computed(() =>
  REVIEW_STATUS_DEFS.map(f => ({
    ...f,
    count: props.tasks.filter(t => (t.review_status ?? 'none') === f.status).length,
  })).filter(f => f.count > 0)
)

const reviewFilterVisible = computed(() =>
  props.tasks.some(t => t.review_status && t.review_status !== 'none')
)

const STATUS_FILTER_DEFS = [
  { status: 'pending',         icon: '▶',  label: 'Pending',         activeClass: 'bg-slate-700 text-slate-300' },
  { status: 'underway',        icon: '⏳', label: 'Underway',        activeClass: 'bg-amber-900/60 text-amber-300' },
  { status: 'auto-queue',      icon: '⏱',  label: 'Auto-queued',     activeClass: 'bg-cyan-900/60 text-cyan-300' },
  { status: 'awaiting-commit', icon: '💾', label: 'Awaiting commit', activeClass: 'bg-purple-900/60 text-purple-300' },
  { status: 'awaiting-plan',   icon: '📋', label: 'Awaiting plan',   activeClass: 'bg-teal-900/60 text-teal-300' },
  { status: 'done',            icon: '✅', label: 'Done',            activeClass: 'bg-green-900/40 text-green-400' },
  { status: 'deferred',        icon: '💤', label: 'Deferred',        activeClass: 'bg-slate-700 text-slate-400' },
]

const statusFilters = computed(() =>
  STATUS_FILTER_DEFS.map(f => ({
    ...f,
    count: props.tasks.filter(t => t.status === f.status).length,
  }))
)

const TYPE_FILTER_DEFS = [
  { type: 'task',          icon: '📝', label: 'Task',          activeClass: 'bg-blue-900/60 text-blue-300' },
  { type: 'plan',          icon: '📜', label: 'Plan',          activeClass: 'bg-purple-900/60 text-purple-300' },
  { type: 'make-plan',     icon: '🗂️', label: 'Make-plan',     activeClass: 'bg-teal-900/60 text-teal-300' },
  { type: 'investigate',   icon: '🔍', label: 'Investigate',   activeClass: 'bg-indigo-900/60 text-indigo-300' },
  { type: 'auto-test',     icon: '🧪', label: 'Auto-test',     activeClass: 'bg-yellow-900/60 text-yellow-300' },
  { type: 'auto-commit',   icon: '⚙️', label: 'Auto-commit',   activeClass: 'bg-green-900/60 text-green-300' },
  { type: 'manual-test',   icon: '🔬', label: 'Manual-test',   activeClass: 'bg-yellow-900/40 text-yellow-400' },
  { type: 'manual-commit', icon: '✍️', label: 'Manual-commit', activeClass: 'bg-orange-900/60 text-orange-300' },
  { type: 'manual-task',   icon: '👤', label: 'Manual-task',   activeClass: 'bg-slate-700 text-slate-300' },
  { type: 'unnamed-task',  icon: '💬', label: 'Unnamed-task',  activeClass: 'bg-blue-900/40 text-blue-400' },
]

const activeTypeFilters = reactive(new Set<string>())

function toggleTypeFilter(type: string) {
  if (activeTypeFilters.has(type)) activeTypeFilters.delete(type)
  else activeTypeFilters.add(type)
}

function toggleTypeFilterExclusive(type: string) {
  if (activeTypeFilters.size === 1 && activeTypeFilters.has(type)) {
    activeTypeFilters.clear()
  } else {
    activeTypeFilters.clear()
    activeTypeFilters.add(type)
  }
}

function toggleTypeFilterInverted(type: string) {
  if (activeTypeFilters.has(type)) {
    activeTypeFilters.delete(type)
  } else {
    activeTypeFilters.clear()
    for (const f of TYPE_FILTER_DEFS) { if (f.type !== type) activeTypeFilters.add(f.type) }
  }
}

const typeFilters = computed(() =>
  TYPE_FILTER_DEFS.map(f => ({
    ...f,
    count: props.tasks.filter(t => t.task_type === f.type).length,
  }))
)

const pendingCount = computed(() => props.tasks.filter(t => t.status === 'pending').length)
const underwayCount = computed(() => props.tasks.filter(t => t.status === 'underway').length)
const doneCount = computed(() => props.tasks.filter(t => t.status === 'done').length)
const autoQueueCount = computed(() => props.tasks.filter(t => t.status === 'auto-queue').length)
const awaitingCommitCount = computed(() => props.tasks.filter(t => t.status === 'awaiting-commit').length)
const awaitingPlanCount = computed(() => props.tasks.filter(t => t.status === 'awaiting-plan').length)
// Warn if there are multiple underway tasks alongside auto-queue tasks (suggests >1 auto runner)
const multipleAutoWarning = computed(() => autoQueueCount.value > 0 && underwayCount.value > 1)

function archiveBadgeClass(taskType: string): string {
  return ({
    'task': 'bg-blue-900/40 text-blue-400',
    'plan': 'bg-purple-900/40 text-purple-400',
    'make-plan': 'bg-teal-900/40 text-teal-400',
    'investigate': 'bg-indigo-900/40 text-indigo-400',
    'auto-test': 'bg-yellow-900/40 text-yellow-400',
    'auto-commit': 'bg-green-900/40 text-green-400',
    'manual-test': 'bg-yellow-900/30 text-yellow-500',
    'manual-commit': 'bg-orange-900/40 text-orange-400',
    'manual-task': 'bg-slate-700/60 text-slate-400',
    'unnamed-task': 'bg-blue-900/30 text-blue-500',
  } as Record<string, string>)[taskType] ?? 'bg-slate-700/60 text-slate-400'
}

const cid = () => props.containerId

async function addTask(taskType: string, filename: string | null, description: string | null, createFile = false, commitMode: 'none' | 'auto' | 'stage' | 'manual' = 'none', planDisposition?: 'manual' | 'add-after' | 'add-end' | 'add-subtask', autoQueuePlan?: boolean, parentTaskId?: number, linkType?: 'follow-up' | 'fix-required' | 'check' | 'other', subtasks?: SubtaskEntry[], autoQueue?: boolean) {
  console.log(`[planq] add task type=${taskType} file=${filename ?? '—'} commit_mode=${commitMode} auto_queue=${!!autoQueue} container=${cid()}`)
  const created = await apiAdd(props.containerId, taskType, filename, description, createFile, commitMode, planDisposition, autoQueuePlan, parentTaskId, linkType, autoQueue)
  if (created && subtasks?.length) {
    for (const sub of subtasks) {
      const subFile = sub.filename.trim() || null
      const subDesc = sub.description.trim() || null
      if (!subFile && !subDesc) continue
      // A file-based type with no filename becomes an unnamed-task (avoids description-as-filename confusion)
      const subType = !subFile && sub.type === 'task' ? 'unnamed-task' : sub.type
      await apiAdd(props.containerId, subType, subFile, subDesc, !!subFile, 'none', undefined, undefined, created.id, sub.linkType)
    }
  }
  emit('tasks-changed')
}

async function setStatus(task: PlanqTask, status: 'pending' | 'done' | 'underway' | 'auto-queue' | 'awaiting-commit' | 'awaiting-plan' | 'deferred') {
  console.log(`[planq] set status ${task.status}→${status} task=${task.filename ?? task.description} container=${cid()}`)
  updatePlanqTaskOptimistic(props.containerId, task.id, { status })
  await apiUpdate(props.containerId, task.id, { status })
  emit('tasks-changed')
}

async function deleteTask(id: number) {
  const task = props.tasks.find(t => t.id === id)
  console.log(`[planq] delete task=${task?.filename ?? task?.description ?? id} container=${cid()}`)
  await apiDelete(props.containerId, id)
  emit('tasks-changed')
}

async function updateDesc(id: number, desc: string) {
  console.log(`[planq] update desc task=${id} container=${cid()}`)
  await apiUpdate(props.containerId, id, { description: desc })
  emit('tasks-changed')
}

async function archiveTask(id: number) {
  await apiArchiveTask(props.containerId, id)
  emit('tasks-changed')
  if (archiveOpen.value) {
    archiveTasks.value = await apiFetchArchive(props.containerId)
  }
}

async function unarchiveTask(historyIndex: number) {
  await apiUnarchiveTask(props.containerId, historyIndex)
  emit('tasks-changed')
  archiveTasks.value = await apiFetchArchive(props.containerId)
}

async function archiveDone() {
  const count = await apiArchiveDone(props.containerId)
  emit('tasks-changed')
  if (archiveOpen.value && count > 0) {
    archiveTasks.value = await apiFetchArchive(props.containerId)
  }
}

async function setReviewStatus(task: PlanqTask, status: ReviewStatus) {
  updatePlanqTaskOptimistic(props.containerId, task.id, { review_status: status })
  await apiUpdate(props.containerId, task.id, { review_status: status })
  emit('tasks-changed')
}

async function setCommitMode(task: PlanqTask, mode: 'none' | 'auto' | 'stage' | 'manual') {
  console.log(`[planq] set commit_mode=${mode} task=${task.filename ?? task.description} container=${cid()}`)
  await apiUpdate(props.containerId, task.id, { commit_mode: mode })
  emit('tasks-changed')
}

const respondingAutoTest = ref(false)

async function respondAutoTest(response: 'continue' | 'abort') {
  respondingAutoTest.value = true
  await apiRespondAutoTest(props.containerId, response)
  respondingAutoTest.value = false
}

async function addPlanFromMakePlan(planFilename: string) {
  console.log(`[planq] add plan from make-plan file=${planFilename} container=${cid()}`)
  await apiAdd(props.containerId, 'plan', planFilename, null, false)
  emit('tasks-changed')
}

async function dropOn(targetId: number) {
  if (dragFrom.value === null || dragFrom.value === targetId) {
    dragFrom.value = null
    return
  }
  const allTasks = [...props.tasks]
  const fromTask = allTasks.find(t => t.id === dragFrom.value)
  const toTask = allTasks.find(t => t.id === targetId)
  if (!fromTask || !toTask) { dragFrom.value = null; return }

  // Subtasks can only be reordered within the same parent
  if (fromTask.parent_task_id !== toTask.parent_task_id) {
    dragFrom.value = null
    return
  }

  const fromIdx = allTasks.findIndex(t => t.id === dragFrom.value)
  const toIdx = allTasks.findIndex(t => t.id === targetId)
  if (fromIdx < 0 || toIdx < 0) { dragFrom.value = null; return }
  const [moved] = allTasks.splice(fromIdx, 1)
  allTasks.splice(toIdx, 0, moved)
  const reorder = allTasks.map((t, i) => ({ id: t.id, position: i }))
  dragFrom.value = null
  await apiReorder(props.containerId, reorder)
  emit('tasks-changed')
}
</script>
