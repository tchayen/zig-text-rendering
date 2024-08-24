#include "lunasvg.h"
#include "svgelement.h"
#include "svgparserutils.h"

namespace lunasvg {

struct SimpleSelector;

using Selector = std::vector<SimpleSelector>;
using SelectorList = std::vector<Selector>;

struct AttributeSelector {
    enum class MatchType {
        None,
        Equal,
        Includes,
        DashMatch,
        StartsWith,
        EndsWith,
        Contains
    };

    MatchType matchType{MatchType::None};
    PropertyID id{PropertyID::Unknown};
    std::string value;
};

struct PseudoClassSelector {
    enum class Type {
        Unknown,
        Empty,
        Root,
        Is,
        Not,
        FirstChild,
        LastChild,
        OnlyChild,
        FirstOfType,
        LastOfType,
        OnlyOfType
    };

    Type type{Type::Unknown};
    SelectorList subSelectors;
};

struct SimpleSelector {
    enum class Combinator {
        Descendant,
        Child,
        DirectAdjacent,
        InDirectAdjacent
    };

    Combinator combinator{Combinator::Descendant};
    ElementID id{ElementID::Star};
    std::vector<AttributeSelector> attributeSelectors;
    std::vector<PseudoClassSelector> pseudoClassSelectors;
};

struct Declaration {
    int specificity;
    PropertyID id;
    std::string value;
};

using DeclarationList = std::vector<Declaration>;

struct Rule {
    SelectorList selectors;
    DeclarationList declarations;
};

class RuleData {
public:
    RuleData(const Selector& selector, const DeclarationList& declarations, uint32_t specificity, uint32_t position)
        : m_selector(selector), m_declarations(declarations), m_specificity(specificity), m_position(position)
    {}

    bool isLessThan(const RuleData& rule) const { return std::tie(m_specificity, m_position) < std::tie(rule.m_specificity, rule.m_position); }

    const Selector& selector() const { return m_selector; }
    const DeclarationList& declarations() const { return m_declarations; }
    uint32_t specificity() const { return m_specificity; }
    uint32_t position() const { return m_position; }

    bool match(const SVGElement* element) const;

private:
    static bool matchSimpleSelector(const SimpleSelector& selector, const SVGElement* element);
    static bool matchAttributeSelector(const AttributeSelector& selector, const SVGElement* element);
    static bool matchPseudoClassSelector(const PseudoClassSelector& selector, const SVGElement* element);

    Selector m_selector;
    DeclarationList m_declarations;
    uint32_t m_specificity;
    uint32_t m_position;
};

inline bool operator<(const RuleData& a, const RuleData& b) { return a.isLessThan(b); }

using RuleDataList = std::vector<RuleData>;

class StyleSheet {
public:
    StyleSheet() = default;

    bool parseSheet(std::string_view input);
    const RuleDataList& rules() const { return m_rules; }
    bool isEmpty() const { return m_rules.empty(); }

    void sortRules();

private:
    static bool parseAtRule(std::string_view& input);
    static bool parseRule(std::string_view& input, Rule& rule);
    static bool parseSelectors(std::string_view& input, SelectorList& selectors);
    static bool parseDeclarations(std::string_view& input, DeclarationList& declarations);
    static bool parseSelector(std::string_view& input, Selector& selector);
    static bool parseSimpleSelector(std::string_view& input, SimpleSelector& simpleSelector);

    RuleDataList m_rules;
    uint32_t m_position{0};
};

bool RuleData::match(const SVGElement* element) const
{
    if(m_selector.empty())
        return false;
    auto it = m_selector.rbegin();
    auto end = m_selector.rend();
    if(!matchSimpleSelector(*it, element))
        return false;
    ++it;

    while(it != end) {
        switch(it->combinator) {
        case SimpleSelector::Combinator::Child:
        case SimpleSelector::Combinator::Descendant:
            element = element->parent();
            break;
        case SimpleSelector::Combinator::DirectAdjacent:
        case SimpleSelector::Combinator::InDirectAdjacent:
            element = element->previousElement();
            break;
        }

        if(element == nullptr)
            return false;
        if(matchSimpleSelector(*it, element)) {
            ++it;
        } else if(it->combinator != SimpleSelector::Combinator::Descendant
            && it->combinator != SimpleSelector::Combinator::InDirectAdjacent) {
            return false;
        }
    }

    return true;
}

bool RuleData::matchSimpleSelector(const SimpleSelector& selector, const SVGElement* element)
{
    if(selector.id != ElementID::Star && selector.id != element->id())
        return false;
    for(const auto& sel : selector.attributeSelectors) {
        if(!matchAttributeSelector(sel, element)) {
            return false;
        }
    }

    for(const auto& sel : selector.pseudoClassSelectors) {
        if(!matchPseudoClassSelector(sel, element)) {
            return false;
        }
    }

    return true;
}

constexpr bool includes(const std::string_view& value, const std::string_view& subvalue)
{
    if(subvalue.empty() || subvalue.length() > value.length())
        return false;
    std::string_view input(value);
    while(!input.empty()) {
        skipOptionalSpaces(input);
        std::string_view start(input);
        while(!input.empty() && !IS_WS(input.front()))
            input.remove_prefix(1);
        if(subvalue == start.substr(0, start.length() - input.length())) {
            return true;
        }
    }

    return false;
}

constexpr bool startswith(const std::string_view& value, const std::string_view& subvalue)
{
    if(subvalue.empty() || subvalue.length() > value.length())
        return false;
    return subvalue == value.substr(0, subvalue.size());
}

constexpr bool endswith(const std::string_view& value, const std::string_view& subvalue)
{
    if(subvalue.empty() || subvalue.length() > value.length())
        return false;
    return subvalue == value.substr(value.size() - subvalue.size(), subvalue.size());
}

constexpr bool dashequals(const std::string_view& value, const std::string_view& subvalue)
{
    if(startswith(value, subvalue))
        return (value.length() == subvalue.length() || value.at(subvalue.length()) == '-');
    return false;
}

bool RuleData::matchAttributeSelector(const AttributeSelector& selector, const SVGElement* element)
{
    const auto& value = element->getAttribute(selector.id);
    if(value.empty())
        return false;
    if(selector.matchType == AttributeSelector::MatchType::None)
        return true;
    if(selector.matchType == AttributeSelector::MatchType::Equal)
        return selector.value == value;
    if(selector.matchType == AttributeSelector::MatchType::Includes)
        return includes(value, selector.value);
    if(selector.matchType == AttributeSelector::MatchType::DashMatch)
        return dashequals(value, selector.value);
    if(selector.matchType == AttributeSelector::MatchType::StartsWith)
        return startswith(value, selector.value);
    if(selector.matchType == AttributeSelector::MatchType::EndsWith)
        return endswith(value, selector.value);
    if(selector.matchType == AttributeSelector::MatchType::Contains)
        return value.find(selector.value) != std::string::npos;
    return false;
}

bool RuleData::matchPseudoClassSelector(const PseudoClassSelector& selector, const SVGElement* element)
{
    if(selector.type == PseudoClassSelector::Type::Empty)
        return element->children().empty();
    if(selector.type == PseudoClassSelector::Type::Root)
        return element->parent() == nullptr;
    if(selector.type == PseudoClassSelector::Type::Is) {
        for(const auto& subSelector : selector.subSelectors) {
            for(const auto& sel : subSelector) {
                if(!matchSimpleSelector(sel, element)) {
                    return false;
                }
            }
        }

        return true;
    }

    if(selector.type == PseudoClassSelector::Type::Not) {
        for(const auto& subSelector : selector.subSelectors) {
            for(const auto& sel : subSelector) {
                if(matchSimpleSelector(sel, element)) {
                    return false;
                }
            }
        }

        return true;
    }

    if(selector.type == PseudoClassSelector::Type::FirstChild)
        return !element->previousElement();
    if(selector.type == PseudoClassSelector::Type::LastChild)
        return !element->nextElement();
    if(selector.type == PseudoClassSelector::Type::OnlyChild)
        return !(element->previousElement() || element->nextElement());
    if(selector.type == PseudoClassSelector::Type::FirstOfType) {
        auto sibling = element->previousElement();
        while(sibling) {
            if(sibling->id() == element->id())
                return false;
            sibling = element->previousElement();
        }

        return true;
    }

    if(selector.type == PseudoClassSelector::Type::LastOfType) {
        auto sibling = element->nextElement();
        while(sibling) {
            if(sibling->id() == element->id())
                return false;
            sibling = element->nextElement();
        }

        return true;
    }

    return false;
}

constexpr bool IS_CSS_STARTNAMECHAR(int c) { return IS_ALPHA(c) || c == '_' || c == '-'; }
constexpr bool IS_CSS_NAMECHAR(int c) { return IS_CSS_STARTNAMECHAR(c) || IS_NUM(c); }
inline bool readCSSIdentifier(std::string_view& input, std::string& output)
{
    if(input.empty() || !IS_CSS_STARTNAMECHAR(input.front()))
        return false;
    output.clear();
    do {
        output.push_back(input.front());
        input.remove_prefix(1);
    } while(!input.empty() && IS_CSS_NAMECHAR(input.front()));
    return true;
}

bool StyleSheet::parseSheet(std::string_view input)
{
    Rule rule;
    while(!input.empty()) {
        skipOptionalSpaces(input);
        if(skipDelimiter(input, '@')) {
            if(!parseAtRule(input))
                return false;
            continue;
        }

        if(!parseRule(input, rule))
            return false;
        for(const auto& selector : rule.selectors) {
            uint32_t specificity = 0;
            for(const auto& simpleSelector : selector) {
                specificity += (simpleSelector.id == ElementID::Star) ? 0x0 : 0x1;
                for(const auto& attributeSelector : simpleSelector.attributeSelectors) {
                    specificity += (attributeSelector.id == PropertyID::Id) ? 0x10000 : 0x100;
                }
            }

            m_rules.emplace_back(selector, rule.declarations, specificity, m_position);
        }

        m_position += 1;
    }

    return true;
}

void StyleSheet::sortRules()
{
    std::sort(m_rules.begin(), m_rules.end());
}

bool StyleSheet::parseAtRule(std::string_view& input)
{
    int depth = 0;
    while(!input.empty()) {
        auto ch = input.front();
        input.remove_prefix(1);
        if(ch == ';' && depth == 0)
            break;
        if(ch == '{') ++depth;
        else if(ch == '}' && depth > 0) {
            if(depth == 1)
                break;
            --depth;
        }
    }

    return true;
}

bool StyleSheet::parseRule(std::string_view& input, Rule& rule)
{
    rule.selectors.clear();
    rule.declarations.clear();
    if(!parseSelectors(input, rule.selectors))
        return false;
    if(!parseDeclarations(input, rule.declarations))
        return false;
    return true;
}

bool StyleSheet::parseSelectors(std::string_view& input, SelectorList& selectors)
{
    do {
        Selector selector;
        if(!parseSelector(input, selector))
            return false;
        selectors.push_back(std::move(selector));
    } while(skipDelimiter(input, ',') && skipOptionalSpaces(input));
    return true;
}

bool StyleSheet::parseDeclarations(std::string_view& input, DeclarationList& declarations)
{
    if(!skipDelimiter(input, '{'))
        return false;
    skipOptionalSpaces(input);
    do {
        std::string name;
        if(!readCSSIdentifier(input, name))
            return false;
        skipOptionalSpaces(input);
        if(!skipDelimiter(input, ':'))
            return false;
        skipOptionalSpaces(input);
        std::string_view value(input);
        while(!input.empty() && !(input.front() == '!' || input.front() == ';' || input.front() == '}'))
            input.remove_prefix(1);
        value.remove_suffix(input.length());
        stripTrailingSpaces(value);

        Declaration declaration;
        declaration.specificity = 0x10;
        declaration.id = csspropertyid(name);
        declaration.value.assign(value);
        if(skipDelimiter(input, '!')) {
            skipOptionalSpaces(input);
            if(!skipString(input, "important"))
                return false;
            declaration.specificity = 0x1000;
        }

        if(declaration.id != PropertyID::Unknown)
            declarations.push_back(std::move(declaration));
        skipOptionalSpacesOrDelimiter(input, ';');
    } while(!input.empty() && input.front() != '}');
    return skipDelimiter(input, '}');
}

constexpr bool IS_SELECTOR_STARTNAMECHAR(int c) { return IS_CSS_STARTNAMECHAR(c) || c == '*' || c == '#' || c == '.' || c == '[' || c == ':'; }
bool StyleSheet::parseSelector(std::string_view& input, Selector& selector)
{
    do {
        SimpleSelector simpleSelector;
        if(!parseSimpleSelector(input, simpleSelector))
            return false;
        selector.push_back(std::move(simpleSelector));
        skipOptionalSpaces(input);
    } while(!input.empty() && IS_SELECTOR_STARTNAMECHAR(input.front()));
    return true;
}

bool StyleSheet::parseSimpleSelector(std::string_view& input, SimpleSelector& simpleSelector)
{
    std::string name;
    if(skipDelimiter(input, '*'))
        simpleSelector.id = ElementID::Star;
    else if(readCSSIdentifier(input, name))
        simpleSelector.id = elementid(name);
    while(!input.empty()) {
        if(input.front() == ':') {
            input.remove_prefix(1);
            if(!readCSSIdentifier(input, name))
                return false;
            PseudoClassSelector selector;
            if(name.compare("empty") == 0)
                selector.type = PseudoClassSelector::Type::Empty;
            else if(name.compare("root") == 0)
                selector.type = PseudoClassSelector::Type::Root;
            else if(name.compare("not") == 0)
                selector.type = PseudoClassSelector::Type::Not;
            else if(name.compare("first-child") == 0)
                selector.type = PseudoClassSelector::Type::FirstChild;
            else if(name.compare("last-child") == 0)
                selector.type = PseudoClassSelector::Type::LastChild;
            else if(name.compare("only-child") == 0)
                selector.type = PseudoClassSelector::Type::OnlyChild;
            else if(name.compare("first-of-type") == 0)
                selector.type = PseudoClassSelector::Type::FirstOfType;
            else if(name.compare("last-of-type") == 0)
                selector.type = PseudoClassSelector::Type::LastOfType;
            else if(name.compare("only-of-type") == 0)
                selector.type = PseudoClassSelector::Type::OnlyOfType;
            if(selector.type == PseudoClassSelector::Type::Is || selector.type == PseudoClassSelector::Type::Not) {
                skipOptionalSpaces(input);
                if(!skipDelimiter(input, '('))
                    return false;
                skipOptionalSpaces(input);
                if(!parseSelectors(input, selector.subSelectors))
                    return false;
                skipOptionalSpaces(input);
                if(!skipDelimiter(input, ')')) {
                    return false;
                }
            }

            simpleSelector.pseudoClassSelectors.push_back(std::move(selector));
            continue;
        }

        if(input.front() == '#') {
            input.remove_prefix(1);
            AttributeSelector a;
            a.id = PropertyID::Id;
            a.matchType = AttributeSelector::MatchType::Equal;
            if(!readCSSIdentifier(input, a.value))
                return false;
            simpleSelector.attributeSelectors.push_back(std::move(a));
            continue;
        }

        if(input.front() == '.') {
            input.remove_prefix(1);
            AttributeSelector a;
            a.id = PropertyID::Class;
            a.matchType = AttributeSelector::MatchType::Includes;
            if(!readCSSIdentifier(input, a.value))
                return false;
            simpleSelector.attributeSelectors.push_back(std::move(a));
            continue;
        }

        if(input.front() == '[') {
            input.remove_prefix(1);
            skipOptionalSpaces(input);
            if(!readCSSIdentifier(input, name))
                return false;
            AttributeSelector a;
            a.id = propertyid(name);
            if(skipDelimiter(input, '='))
                a.matchType = AttributeSelector::MatchType::Equal;
            else if(skipString(input, "~="))
                a.matchType = AttributeSelector::MatchType::Includes;
            else if(skipString(input, "|="))
                a.matchType = AttributeSelector::MatchType::DashMatch;
            else if(skipString(input, "^="))
                a.matchType = AttributeSelector::MatchType::StartsWith;
            else if(skipString(input, "$="))
                a.matchType = AttributeSelector::MatchType::EndsWith;
            else if(skipString(input, "*="))
                a.matchType = AttributeSelector::MatchType::Contains;
            if(a.matchType != AttributeSelector::MatchType::None) {
                skipOptionalSpaces(input);
                if(!readCSSIdentifier(input, a.value)) {
                    if(input.empty() || !(input.front() == '\"' || input.front() == '\''))
                        return false;
                    auto quote = input.front();
                    input.remove_prefix(1);
                    auto n = input.find(quote);
                    if(n == std::string_view::npos)
                        return false;
                    a.value.assign(input.substr(0, n));
                    input.remove_prefix(n + 1);
                }
            }

            skipOptionalSpaces(input);
            if(!skipDelimiter(input, ']'))
                return false;
            simpleSelector.attributeSelectors.push_back(std::move(a));
            continue;
        }

        break;
    }

    skipOptionalSpaces(input);
    if(skipDelimiter(input, '>'))
        simpleSelector.combinator = SimpleSelector::Combinator::Child;
    else if(skipDelimiter(input, '+'))
        simpleSelector.combinator = SimpleSelector::Combinator::DirectAdjacent;
    else if(skipDelimiter(input, '~'))
        simpleSelector.combinator = SimpleSelector::Combinator::InDirectAdjacent;
    return true;
}

inline void parseStyle(std::string_view input, SVGElement* element)
{
    std::string name;
    std::string value;
    skipOptionalSpaces(input);
    while(readCSSIdentifier(input, name)) {
        skipOptionalSpaces(input);
        if(!skipDelimiter(input, ':'))
            return;
        value.clear();
        while(!input.empty() && input.front() != ';') {
            value.push_back(input.front());
            input.remove_prefix(1);
        }

        auto id = csspropertyid(name);
        if(id != PropertyID::Unknown)
            element->setAttribute(0x100, id, value);
        skipOptionalSpacesOrDelimiter(input, ';');
    }
}

inline void removeStyleComments(std::string& value)
{
    auto start = value.find("/*");
    while(start != std::string::npos) {
        auto end = value.find("*/", start + 2);
        value.erase(start, end - start + 2);
        start = value.find("/*");
    }
}

inline bool decodeText(std::string_view input, std::string& output)
{
    output.clear();
    while(!input.empty()) {
        auto ch = input.front();
        input.remove_prefix(1);
        if(ch != '&') {
            output.push_back(ch);
            continue;
        }

        if(skipDelimiter(input, '#')) {
            int base = 10;
            if(skipDelimiter(input, 'x'))
                base = 16;
            unsigned int cp;
            if(!parseInteger(input, cp, base))
                return false;
            char c[5] = {0, 0, 0, 0, 0};
            if(cp < 0x80) {
                c[1] = 0;
                c[0] = char(cp);
            } else if(cp < 0x800) {
                c[2] = 0;
                c[1] = char((cp & 0x3F) | 0x80);
                cp >>= 6;
                c[0] = char(cp | 0xC0);
            } else if(cp < 0x10000) {
                c[3] = 0;
                c[2] = char((cp & 0x3F) | 0x80);
                cp >>= 6;
                c[1] = char((cp & 0x3F) | 0x80);
                cp >>= 6;
                c[0] = char(cp | 0xE0);
            } else if(cp < 0x200000) {
                c[4] = 0;
                c[3] = char((cp & 0x3F) | 0x80);
                cp >>= 6;
                c[2] = char((cp & 0x3F) | 0x80);
                cp >>= 6;
                c[1] = char((cp & 0x3F) | 0x80);
                cp >>= 6;
                c[0] = char(cp | 0xF0);
            }

            output.append(c);
        } else {
            if(skipString(input, "amp")) {
                output.push_back('&');
            } else if(skipString(input, "lt")) {
                output.push_back('<');
            } else if(skipString(input, "gt")) {
                output.push_back('>');
            } else if(skipString(input, "quot")) {
                output.push_back('\"');
            } else if(skipString(input, "apos")) {
                output.push_back('\'');
            } else {
                return false;
            }
        }

        if(!skipDelimiter(input, ';')) {
            return false;
        }
    }

    return true;
}

constexpr bool IS_STARTNAMECHAR(int c) { return IS_ALPHA(c) ||  c == '_' || c == ':'; }
constexpr bool IS_NAMECHAR(int c) { return IS_STARTNAMECHAR(c) || IS_NUM(c) || c == '-' || c == '.'; }
inline bool readIdentifier(std::string_view& input, std::string& output)
{
    if(input.empty() || !IS_STARTNAMECHAR(input.front()))
        return false;
    output.clear();
    do {
        output.push_back(input.front());
        input.remove_prefix(1);
    } while(!input.empty() && IS_NAMECHAR(input.front()));
    return true;
}

bool Document::parse(const char* data, size_t length)
{
    std::string name;
    std::string value;
    StyleSheet styleSheet;
    SVGElement* currentElement = nullptr;
    int ignoring = 0;
    auto handleText = [&](const std::string_view& text, bool in_cdata) {
        if(text.empty() || !currentElement || (currentElement->id() != ElementID::Text && currentElement->id() != ElementID::TSpan && currentElement->id() != ElementID::Style))
            return;
        if(in_cdata) {
            value.assign(text);
        } else {
            decodeText(text, value);
        }

        if(currentElement->id() == ElementID::Style) {
            removeStyleComments(value);
            styleSheet.parseSheet(value);
        } else {
            auto node = std::make_unique<SVGTextNode>(this);
            node->setText(value);
            currentElement->addChild(std::move(node));
        }
    };

    std::string_view input(data, length);
    while(!input.empty()) {
        if(currentElement) {
            auto text = input.substr(0, input.find('<'));
            handleText(text, false);
            input.remove_prefix(text.length());
        } else {
            if(!skipOptionalSpaces(input)) {
                break;
            }
        }

        if(!skipDelimiter(input, '<'))
            return false;
        if(skipDelimiter(input, '?')) {
            if(!readIdentifier(input, name))
                return false;
            auto n = input.find("?>");
            if(n == std::string_view::npos)
                return false;
            input.remove_prefix(n + 2);
            continue;
        }

        if(skipDelimiter(input, '!')) {
            if(skipString(input, "--")) {
                auto n = input.find("-->");
                if(n == std::string_view::npos)
                    return false;
                handleText(input.substr(0, n), false);
                input.remove_prefix(n + 3);
                continue;
            }

            if(skipString(input, "[CDATA[")) {
                auto n = input.find("]]>");
                if(n == std::string_view::npos)
                    return false;
                handleText(input.substr(0, n), true);
                input.remove_prefix(n + 3);
                continue;
            }

            if(skipString(input, "DOCTYPE")) {
                while(!input.empty() && input.front() != '>') {
                    if(input.front() == '[') {
                        int depth = 1;
                        input.remove_prefix(1);
                        while(!input.empty() && depth > 0) {
                            if(input.front() == '[') ++depth;
                            else if(input.front() == ']') --depth;
                            input.remove_prefix(1);
                        }
                    } else {
                        input.remove_prefix(1);
                    }
                }

                if(!skipDelimiter(input, '>'))
                    return false;
                continue;
            }

            return false;
        }

        if(skipDelimiter(input, '/')) {
            if(currentElement == nullptr && ignoring == 0)
                return false;
            if(!readIdentifier(input, name))
                return false;
            if(ignoring == 0) {
                auto id = elementid(name);
                if(id != currentElement->id())
                    return false;
                currentElement = currentElement->parent();
            } else {
                --ignoring;
            }

            skipOptionalSpaces(input);
            if(!skipDelimiter(input, '>'))
                return false;
            continue;
        }

        if(!readIdentifier(input, name))
            return false;
        SVGElement* element = nullptr;
        if(ignoring > 0) {
            ++ignoring;
        } else {
            auto id = elementid(name);
            if(id == ElementID::Unknown) {
                ignoring = 1;
            } else {
                if(m_rootElement && currentElement == nullptr)
                    return false;
                if(m_rootElement == nullptr) {
                    if(id != ElementID::Svg)
                        return false;
                    m_rootElement = std::make_unique<SVGRootElement>(this);
                    element = m_rootElement.get();
                } else {
                    auto child = SVGElement::create(this, id);
                    element = child.get();
                    currentElement->addChild(std::move(child));
                }
            }
        }

        skipOptionalSpaces(input);
        while(readIdentifier(input, name)) {
            skipOptionalSpaces(input);
            if(!skipDelimiter(input, '='))
                return false;
            skipOptionalSpaces(input);
            if(input.empty() || !(input.front() == '\"' || input.front() == '\''))
                return false;
            auto quote = input.front();
            input.remove_prefix(1);
            auto n = input.find(quote);
            if(n == std::string_view::npos)
                return false;
            auto id = PropertyID::Unknown;
            if(element != nullptr)
                id = propertyid(name);
            if(id != PropertyID::Unknown) {
                decodeText(input.substr(0, n), value);
                if(id == PropertyID::Style) {
                    removeStyleComments(value);
                    parseStyle(value, element);
                } else {
                    if(id == PropertyID::Id)
                        m_rootElement->addElementById(value, element);
                    element->setAttribute(0x1, id, value);
                }
            }

            input.remove_prefix(n + 1);
            skipOptionalSpaces(input);
        }

        if(skipDelimiter(input, '>')) {
            if(element != nullptr)
                currentElement = element;
            continue;
        }

        if(skipDelimiter(input, '/')) {
            if(!skipDelimiter(input, '>'))
                return false;
            if(ignoring > 0)
                --ignoring;
            continue;
        }

        return false;
    }

    if(m_rootElement == nullptr || ignoring > 0 || !input.empty())
        return false;
    if(!styleSheet.isEmpty()) {
        styleSheet.sortRules();
        m_rootElement->transverse([&styleSheet](SVGNode* node) {
            if(node->isTextNode())
                return true;
            auto element = static_cast<SVGElement*>(node);
            for(auto& rule : styleSheet.rules()) {
                if(rule.match(element)) {
                    for(auto& declaration : rule.declarations()) {
                        element->setAttribute(declaration.specificity, declaration.id, declaration.value);
                    }
                }
            }

            return true;
        });
    }

    m_rootElement->build();
    return true;
}

} // namespace lunasvg
