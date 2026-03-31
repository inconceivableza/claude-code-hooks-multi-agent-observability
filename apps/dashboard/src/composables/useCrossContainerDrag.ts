import { ref } from 'vue'
import type { PlanqTask } from '../types'

// Module-level reactive state — shared across all PlanqPanel instances
const dragTask = ref<PlanqTask | null>(null)
const dragContainerId = ref<string | null>(null)

export function useCrossContainerDrag() {
  function startDrag(task: PlanqTask, containerId: string) {
    dragTask.value = task
    dragContainerId.value = containerId
  }

  function endDrag() {
    dragTask.value = null
    dragContainerId.value = null
  }

  return { dragTask, dragContainerId, startDrag, endDrag }
}
