<template>
  <!-- The root stays in place as an empty placeholder; the wrapper is detached on mount and appended to document.body while the modal is shown -->
  <div class="hidden">
    <div ref="wrapper" class="modal modal-bg w-screen fixed bottom-0 left-0 flex items-center justify-center z-50" :class="threeQuartersScreen ? 'h-[75vh] min-h-[400px] short:min-h-0 short:h-screen' : 'h-screen'" @click.stop @touchstart.stop @touchend.stop>
      <div ref="content" class="relative text-fg h-full w-full bg-bg">
        <slot />
      </div>
    </div>
  </div>
</template>

<script>
/**
 * Bottom sheet style modal (ebook reader). Same DOM handling as Modal.vue: the
 * wrapper is moved to document.body while shown and the component root is an
 * empty placeholder, so Vue reordering the parent's children never puts the
 * wrapper back into the page.
 */
export default {
  props: {
    value: Boolean,
    processing: Boolean,
    threeQuartersScreen: Boolean
  },
  data() {
    return {
      el: null,
      content: null
    }
  },
  watch: {
    show(newVal) {
      if (newVal) {
        this.setShow()
      } else {
        this.setHide()
      }
    }
  },
  computed: {
    show: {
      get() {
        return this.value
      },
      set(val) {
        this.$emit('input', val)
      }
    }
  },
  methods: {
    setShow() {
      this.$store.commit('globals/setIsModalOpen', true)

      document.body.appendChild(this.el)
      setTimeout(() => {
        this.content.style.transform = 'translateY(0)'
      }, 10)
      document.documentElement.classList.add('modal-open')
    },
    setHide() {
      this.$store.commit('globals/setIsModalOpen', false)

      this.content.style.transform = 'translateY(100vh)'
      setTimeout(() => {
        this.el.remove()
        document.documentElement.classList.remove('modal-open')
      }, 250)
    },
    closeModalEvt() {
      console.log('Close modal event')
      this.show = false
    }
  },
  mounted() {
    this.$eventBus.$on('close-modal', this.closeModalEvt)
    this.el = this.$refs.wrapper
    this.content = this.$refs.content
    this.content.style.transform = 'translateY(100vh)'
    this.content.style.transition = 'transform 0.25s cubic-bezier(0.16, 1, 0.3, 1)'
    this.el.remove()
  },
  beforeDestroy() {
    this.$eventBus.$off('close-modal', this.closeModalEvt)
    // Destroyed while shown (e.g. the reader closed with the sheet open): the wrapper
    // lives in document.body, where Vue does not remove it, so take it out right away
    if (this.el?.parentNode) {
      this.$store.commit('globals/setIsModalOpen', false)
      this.el.remove()
      document.documentElement.classList.remove('modal-open')
    }
  }
}
</script>
