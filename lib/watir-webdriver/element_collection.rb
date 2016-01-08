module Watir

  #
  # Base class for element collections.
  #

  class ElementCollection
    include Enumerable

    def initialize(parent, selector)
      @parent   = parent
      @selector = selector
    end

    #
    # Yields each element in collection.
    #
    # @example
    #   divs = browser.divs(class: 'kls')
    #   divs.each do |div|
    #     puts div.text
    #   end
    #
    # @yieldparam [Watir::Element] element Iterate through the elements in this collection.
    #

    def each(&blk)
      to_a.each(&blk)
    end

    #
    # Returns number of elements in collection.
    #
    # @return [Fixnum]
    #

    def length
      elements.length
    end
    alias_method :size, :length

    #
    # Get the element at the given index.
    #
    # Also note that because of Watir's lazy loading, this will return an Element
    # instance even if the index is out of bounds.
    #
    # @param [Fixnum] idx Index of wanted element, 0-indexed
    # @return [Watir::Element] Returns an instance of a Watir::Element subclass
    #

    def [](idx)
      to_a[idx] || element_class.new(@parent, @selector.merge(index: idx))
    end

    #
    # First element of this collection
    #
    # @return [Watir::Element] Returns an instance of a Watir::Element subclass
    #

    def first
      self[0]
    end

    #
    # Last element of the collection
    #
    # @return [Watir::Element] Returns an instance of a Watir::Element subclass
    #

    def last
      self[-1]
    end

    #
    # This collection as an Array.
    #
    # @return [Array<Watir::Element>]
    #

    def to_a
      # TODO: optimize - lazy element_class instance?
      @to_a ||= elements.map { |e| element_class.new(@parent, element: e) }
    end

    private

    def elements
      @parent.is_a?(IFrame) ? @parent.switch_to! : @parent.send(:assert_exists)

      @elements ||= locator_class.new(
        @parent.wd,
        @selector,
        element_class.attribute_list,
        element_validator_class,
        selector_builder_class,
        finder_class
      ).locate_all
    end

    def locator_class
      Kernel.const_get(self.class.name.sub(/Collection$/, 'Locator'))
    rescue NameError
      ElementLocator
    end

    def element_validator_class
      Kernel.const_get("#{locator_class}::ElementValidator")
    rescue NameError
      ElementLocator::ElementValidator
    end

    def selector_builder_class
      Kernel.const_get("#{locator_class}::SelectorBuilder")
    rescue NameError
      ElementLocator::SelectorBuilder
    end

    def finder_class
      Kernel.const_get("#{locator_class}::Finder")
    rescue NameError
      ElementLocator::Finder
    end

    def element_class
      Kernel.const_get(self.class.name.sub(/Collection$/, ''))
    end

  end # ElementCollection
end # Watir
