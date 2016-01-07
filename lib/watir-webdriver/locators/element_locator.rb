module Watir
  class ElementLocator
    include Watir::Exception

    def initialize(wd, selector, valid_attributes)
      @wd               = wd
      @selector         = selector.dup
      @valid_attributes = valid_attributes
    end

    def locate
      finder = Finder.new(@wd, @selector, @valid_attributes)
      e = finder.by_id and return e # short-circuit if :id is given

      if @selector.size == 1
        element = finder.find_first_by_one
      else
        element = finder.find_first_by_multiple
      end

      # This actually only applies when finding by xpath/css - browser.text_field(:xpath, "//input[@type='radio']")
      # We don't need to validate the element if we built the xpath ourselves.
      # It is also used to alter behavior of methods locating more than one type of element
      # (e.g. text_field locates both input and textarea)
      ElementValidator.new(element, @selector).validate_element if element
    rescue Selenium::WebDriver::Error::NoSuchElementError, Selenium::WebDriver::Error::StaleElementReferenceError
      nil
    end

    def locate_all
      finder = Finder.new(@wd, @selector, @valid_attributes)

      if @selector.size == 1
        finder.find_all_by_one
      else
        finder.find_all_by_multiple
      end
    end

    private

    class Finder
      WD_FINDERS = [
        :class,
        :class_name,
        :css,
        :id,
        :link,
        :link_text,
        :name,
        :partial_link_text,
        :tag_name,
        :xpath
      ]

      def initialize(wd, selector, valid_attributes)
        @wd = wd
        @selector = selector.dup
        @valid_attributes = valid_attributes
      end

      def by_id
        return unless id = @selector[:id] and id.is_a? String

        selector = @selector.dup
        selector.delete(:id)

        tag_name = selector.delete(:tag_name)
        return unless selector.empty? # multiple attributes

        element = @wd.find_element(:id, id)
        return if tag_name && !TagMatcher.new(element.tag_name.downcase, tag_name).tag_name_matches?

        element
      end

      def find_first_by_one
        how, what = @selector.to_a.first
        SelectorBuild.new(@selector, @valid_attributes).check_type(how, what)

        if WD_FINDERS.include?(how)
          wd_find_first_by(how, what)
        else
          find_first_by_multiple
        end
      end

      def find_first_by_multiple
        selector_builder = SelectorBuild.new(@selector, @valid_attributes)
        selector = selector_builder.normalized_selector

        idx = selector.delete(:index)
        how, what = selector_builder.given_xpath_or_css(selector) || selector_builder.build_wd_selector(selector)

        if how
          # could build xpath/css for selector
          if idx
            @wd.find_elements(how, what)[idx]
          else
            @wd.find_element(how, what)
          end
        else
          # can't use xpath, probably a regexp in there
          if idx
            wd_find_by_regexp_selector(selector, :select)[idx]
          else
            wd_find_by_regexp_selector(selector, :find)
          end
        end
      end

      def find_all_by_one
        how, what = @selector.to_a.first
        SelectorBuild.new(@selector, @valid_attributes).check_type how, what

        if WD_FINDERS.include?(how)
          wd_find_all_by(how, what)
        else
          find_all_by_multiple
        end
      end

      def find_all_by_multiple
        selector_builder = SelectorBuild.new(@selector, @valid_attributes)
        selector = selector_builder.normalized_selector

        if selector.key? :index
          raise ArgumentError, "can't locate all elements by :index"
        end

        how, what = selector_builder.given_xpath_or_css(selector) || selector_builder.build_wd_selector(selector)
        if how
          @wd.find_elements(how, what)
        else
          wd_find_by_regexp_selector(selector, :select)
        end
      end

      def wd_find_all_by(how, what)
        if what.is_a? String
          @wd.find_elements(how, what)
        else
          all_elements.select { |element| fetch_value(element, how) =~ what }
        end
      end

      def fetch_value(element, how)
        case how
        when :text
          element.text
        when :tag_name
          element.tag_name.downcase
        when :href
          (href = element.attribute(:href)) && href.strip
        else
          element.attribute(how.to_s.tr("_", "-").to_sym)
        end
      end

      def all_elements
        @wd.find_elements(xpath: ".//*")
      end

      private

      def wd_find_first_by(how, what)
        if what.is_a? String
          @wd.find_element(how, what)
        else
          all_elements.find { |element| fetch_value(element, how) =~ what }
        end
      end

      def wd_find_by_regexp_selector(selector, method = :find)
        parent = @wd
        rx_selector = delete_regexps_from(selector)

        selector_builder = SelectorBuild.new(@selector, @valid_attributes)

        if rx_selector.key?(:label) && selector_builder.should_use_label_element?
          label = label_from_text(rx_selector.delete(:label)) || return
          if (id = label.attribute(:for))
            selector[:id] = id
          else
            parent = label
          end
        end

        how, what = selector_builder.build_wd_selector(selector)

        unless how
          raise Error, "internal error: unable to build WebDriver selector from #{selector.inspect}"
        end

        if how == :xpath && can_convert_regexp_to_contains?
          rx_selector.each do |key, value|
            next if key == :tag_name || key == :text

            predicates = regexp_selector_to_predicates(key, value)
            what = "(#{what})[#{predicates.join(' and ')}]" unless predicates.empty?
          end
        end

        elements = parent.find_elements(how, what)
        elements.__send__(method) { |el| matches_selector?(el, rx_selector) }
      end

      def delete_regexps_from(selector)
        rx_selector = {}

        selector.dup.each do |how, what|
          next unless what.kind_of?(Regexp)
          rx_selector[how] = what
          selector.delete how
        end

        rx_selector
      end

      def label_from_text(label_exp)
        # TODO: this won't work correctly if @wd is a sub-element
        @wd.find_elements(:tag_name, 'label').find do |el|
          matches_selector?(el, text: label_exp)
        end
      end

      def matches_selector?(element, selector)
        selector.all? do |how, what|
          what === fetch_value(element, how)
        end
      end

      def can_convert_regexp_to_contains?
        true
      end

      # Regular expressions that can be reliably converted to xpath `contains`
      # expressions in order to optimize the locator.
      #
      CONVERTABLE_REGEXP = %r{
        \A
        ([^\[\]\\^$.|?*+()]*) # leading literal characters
        [^|]*?                # do not try to convert expressions with alternates
          ([^\[\]\\^$.|?*+()]*) # trailing literal characters
        \z
      }x

      def regexp_selector_to_predicates(key, re)
        return [] if re.casefold?

        match = re.source.match(CONVERTABLE_REGEXP)
        return [] unless match

        lhs = SelectorBuild.new(@selector, @valid_attributes).lhs_for(key)
        match.captures.reject(&:empty?).map do |literals|
          "contains(#{lhs}, #{XpathSupport.escape(literals)})"
        end
      end
    end


    class SelectorBuild
      def initialize(selector, valid_attributes)
        @selector = selector
        @valid_attributes = valid_attributes
      end

      def normalized_selector
        selector = {}

        @selector.each do |how, what|
          check_type(how, what)

          how, what = normalize_selector(how, what)
          selector[how] = what
        end

        selector
      end

      def normalize_selector(how, what)
        case how
        when :tag_name, :text, :xpath, :index, :class, :label, :css
          # include :class since the valid attribute is 'class_name'
          # include :for since the valid attribute is 'html_for'
          [how, what]
        when :class_name
          [:class, what]
        when :caption
          [:text, what]
        else
          assert_valid_as_attribute how
          [how, what]
        end
      end

      VALID_WHATS = [String, Regexp]

      def check_type(how, what)
        case how
        when :index
          unless what.is_a?(Fixnum)
            raise TypeError, "expected Fixnum, got #{what.inspect}:#{what.class}"
          end
        else
          unless VALID_WHATS.any? { |t| what.is_a? t }
            raise TypeError, "expected one of #{VALID_WHATS.inspect}, got #{what.inspect}:#{what.class}"
          end
        end
      end

      WILDCARD_ATTRIBUTE = /^(aria|data)_(.+)$/

      def assert_valid_as_attribute(attribute)
        return if valid_attribute?(attribute) || attribute.to_s =~ WILDCARD_ATTRIBUTE
        raise Exception::MissingWayOfFindingObjectException, "invalid attribute: #{attribute.inspect}"
      end

      def valid_attribute?(attribute)
        @valid_attributes && @valid_attributes.include?(attribute)
      end

      def given_xpath_or_css(selector)
        xpath = selector.delete(:xpath)
        css   = selector.delete(:css)
        return unless xpath || css

        if xpath && css
          raise ArgumentError, ":xpath and :css cannot be combined (#{selector.inspect})"
        end

        how, what = if xpath
                      [:xpath, xpath]
                    elsif css
                      [:css, css]
                    end

        if selector.any? && !can_be_combined_with_xpath_or_css?(selector)
          raise ArgumentError, "#{how} cannot be combined with other selectors (#{selector.inspect})"
        end

        [how, what]
      end

      def can_be_combined_with_xpath_or_css?(selector)
        keys = selector.keys
        return true if keys == [:tag_name]

        if selector[:tag_name] == "input"
          return keys.sort == [:tag_name, :type]
        end

        false
      end

      def build_wd_selector(selectors)
        unless selectors.values.any? { |e| e.is_a? Regexp }
          build_css(selectors) || build_xpath(selectors)
        end
      end

      def build_xpath(selectors)
        xpath = ".//"
        xpath << (selectors.delete(:tag_name) || '*').to_s

        selectors.delete :index

        # the remaining entries should be attributes
        unless selectors.empty?
          xpath << "[" << attribute_expression(selectors) << "]"
        end

        p xpath: xpath, selectors: selectors if $DEBUG

        [:xpath, xpath]
      end

      def build_css(selectors)
        return unless use_css?(selectors)

        if selectors.empty?
          css = '*'
        else
          css = ''
          css << (selectors.delete(:tag_name) || '')

          klass = selectors.delete(:class)
          if klass
            if klass.include? ' '
              css << %([class="#{css_escape klass}"])
            else
              css << ".#{klass}"
            end
          end

          href = selectors.delete(:href)
          if href
            css << %([href~="#{css_escape href}"])
          end

          selectors.each do |key, value|
            key = key.to_s.tr("_", "-")
            css << %([#{key}="#{css_escape value}"]) # TODO: proper escaping
          end
        end

        [:css, css]
      end

      def use_css?(selectors)
        return false unless Watir.prefer_css?

        if selectors.key?(:text) || selectors.key?(:label) || selectors.key?(:index)
          return false
        end

        if selectors[:tag_name] == 'input' && selectors.key?(:type)
          return false
        end

        if selectors.key?(:class) && selectors[:class] !~ /^[\w-]+$/ui
          return false
        end

        true
      end

      def attribute_expression(selectors)
        f = selectors.map do |key, val|
          if val.is_a?(Array)
            "(" + val.map { |v| equal_pair(key, v) }.join(" or ") + ")"
          else
            equal_pair(key, val)
          end
        end
        f.join(" and ")
      end

      def css_escape(str)
        str.gsub('"', '\\"')
      end

      def equal_pair(key, value)
        if key == :class
          klass = XpathSupport.escape " #{value} "
          "contains(concat(' ', @class, ' '), #{klass})"
        elsif key == :label && should_use_label_element?
          # we assume :label means a corresponding label element, not the attribute
          text = "normalize-space()=#{XpathSupport.escape value}"
          "(@id=//label[#{text}]/@for or parent::label[#{text}])"
        else
          "#{lhs_for(key)}=#{XpathSupport.escape value}"
        end
      end

      def lhs_for(key)
        case key
        when :text, 'text'
          'normalize-space()'
        when :href
          # TODO: change this behaviour?
          'normalize-space(@href)'
        when :type
          # type attributes can be upper case - downcase them
          # https://github.com/watir/watir-webdriver/issues/72
          XpathSupport.downcase('@type')
        else
          "@#{key.to_s.tr("_", "-")}"
        end
      end

      def should_use_label_element?
        !valid_attribute?(:label)
      end
    end


    class TagMatcher
      def initialize(element_tag_name, tag_name)
        @element_tag_name = element_tag_name
        @tag_name = tag_name
      end

      def tag_name_matches?
        @tag_name === @element_tag_name
      end
    end

    class ElementValidator
      def initialize(element, selector)
        @element = element
        @selector = selector
      end

      def validate_element
        tn = @selector[:tag_name]
        element_tag_name = @element.tag_name.downcase

        return if tn && !TagMatcher.new(element_tag_name, tn).tag_name_matches?

        if element_tag_name == 'input'
          return if @selector[:type] && @selector[:type] != @element.attribute(:type)
        end

        @element
      end
    end

  end # ElementLocator
end # Watir
