#if os(Linux)
import CGtk
import MonkeysPawCore

/// Native encoding stays behind the tray driver. Labels are values, never
/// interpolated into GVariant text or exposed through diagnostics.
enum StatusNotifierWire {
    static let watcherName = "org.kde.StatusNotifierWatcher"
    static let itemPath = "/StatusNotifierItem"
    static let menuPath = "/Menu"
    static let itemInterface = "org.kde.StatusNotifierItem"
    static let menuInterface = "com.canonical.dbusmenu"

    static func tuple(_ values: [OpaquePointer?]) -> OpaquePointer {
        values.withUnsafeBufferPointer { g_variant_new_tuple($0.baseAddress, UInt($0.count))! }
    }

    static func array(_ elementType: String, _ values: [OpaquePointer?]) -> OpaquePointer {
        let type = g_variant_type_new(elementType)!
        defer { g_variant_type_free(type) }
        return values.withUnsafeBufferPointer { g_variant_new_array(type, $0.baseAddress, UInt($0.count))! }
    }

    private static func dictionary(_ properties: [(String, OpaquePointer?)], names: [String]) -> OpaquePointer {
        let values: [OpaquePointer?] = properties.compactMap { name, value in
            if !names.isEmpty && !names.contains(name) {
                // These freshly constructed values still have floating refs.
                g_variant_ref_sink(value)
                g_variant_unref(value)
                return nil
            }
            return g_variant_new_dict_entry(g_variant_new_string(name), g_variant_new_variant(value))
        }
        return array("{sv}", values)
    }

    static func properties(_ entry: StatusNotifierEntry?, names: [String]) -> OpaquePointer {
        guard let entry else {
            return dictionary([("children-display", g_variant_new_string("submenu"))], names: names)
        }
        if entry.kind == .separator {
            return dictionary([("type", g_variant_new_string("separator")),
                               ("visible", g_variant_new_boolean(1))], names: names)
        }
        return dictionary([("label", g_variant_new_string(entry.label)),
                           ("enabled", g_variant_new_boolean(entry.enabled ? 1 : 0)),
                           ("visible", g_variant_new_boolean(1))], names: names)
    }

    static func layout(_ entry: StatusNotifierEntry?, children: [StatusNotifierEntry], names: [String]) -> OpaquePointer {
        tuple([g_variant_new_int32(entry?.id ?? 0), properties(entry, names: names),
               array("v", children.map { g_variant_new_variant(layout($0, children: [], names: names)) })])
    }

    static func groupProperties(_ entries: [StatusNotifierEntry], names: [String]) -> OpaquePointer {
        array("(ia{sv})", entries.map { tuple([g_variant_new_int32($0.id), properties($0, names: names)]) })
    }

    static func strings(_ value: OpaquePointer) -> [String] {
        (0..<g_variant_n_children(value)).map {
            let child = g_variant_get_child_value(value, $0)!
            defer { g_variant_unref(child) }
            return String(cString: g_variant_get_string(child, nil))
        }
    }

    static func ids(_ value: OpaquePointer) -> [Int32] {
        (0..<g_variant_n_children(value)).map {
            let child = g_variant_get_child_value(value, $0)!
            defer { g_variant_unref(child) }
            return g_variant_get_int32(child)
        }
    }

    static func property(_ name: String, interface: String) -> OpaquePointer? {
        if interface == menuInterface {
            switch name {
            case "Version": return g_variant_new_uint32(3)
            case "TextDirection": return g_variant_new_string("ltr")
            case "Status": return g_variant_new_string("normal")
            case "IconThemePath": return array("s", [])
            default: return nil
            }
        }
        switch name {
        case "Category": return g_variant_new_string("ApplicationStatus")
        case "Id", "IconName": return g_variant_new_string(AppIdentity.linuxAppID)
        case "Title": return g_variant_new_string(AppIdentity.displayName)
        case "Status": return g_variant_new_string("Active")
        case "WindowId": return g_variant_new_int32(0)
        // False lets hosts send Activate on primary click; the menu stays on secondary click.
        case "ItemIsMenu": return g_variant_new_boolean(0)
        case "Menu": return g_variant_new_object_path(menuPath)
        case "IconThemePath", "OverlayIconName", "AttentionIconName", "AttentionMovieName":
            return g_variant_new_string("")
        case "IconPixmap", "OverlayIconPixmap", "AttentionIconPixmap": return array("(iiay)", [])
        case "ToolTip": return tuple([g_variant_new_string(AppIdentity.linuxAppID), array("(iiay)", []),
                                      g_variant_new_string(AppIdentity.displayName), g_variant_new_string("")])
        default: return nil
        }
    }

    // KDE SNI and DBusMenu v3 wire shapes. GDBus supplies Properties and
    // Introspectable automatically for these registered interfaces.
    static let xml = """
        <node>
          <interface name='org.kde.StatusNotifierItem'>
            <property name='Category' type='s' access='read'/>
            <property name='Id' type='s' access='read'/>
            <property name='Title' type='s' access='read'/>
            <property name='Status' type='s' access='read'/>
            <property name='WindowId' type='i' access='read'/>
            <property name='IconThemePath' type='s' access='read'/>
            <property name='ItemIsMenu' type='b' access='read'/>
            <property name='Menu' type='o' access='read'/>
            <property name='IconName' type='s' access='read'/>
            <property name='IconPixmap' type='a(iiay)' access='read'/>
            <property name='OverlayIconName' type='s' access='read'/>
            <property name='OverlayIconPixmap' type='a(iiay)' access='read'/>
            <property name='AttentionIconName' type='s' access='read'/>
            <property name='AttentionIconPixmap' type='a(iiay)' access='read'/>
            <property name='AttentionMovieName' type='s' access='read'/>
            <property name='ToolTip' type='(sa(iiay)ss)' access='read'/>
            <method name='Activate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>
            <method name='ContextMenu'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>
            <method name='SecondaryActivate'><arg type='i' direction='in'/><arg type='i' direction='in'/></method>
            <method name='Scroll'><arg type='i' direction='in'/><arg type='s' direction='in'/></method>
          </interface>
          <interface name='com.canonical.dbusmenu'>
            <property name='Version' type='u' access='read'/>
            <property name='TextDirection' type='s' access='read'/>
            <property name='Status' type='s' access='read'/>
            <property name='IconThemePath' type='as' access='read'/>
            <method name='GetLayout'><arg type='i' direction='in'/><arg type='i' direction='in'/>
              <arg type='as' direction='in'/><arg type='u' direction='out'/><arg type='(ia{sv}av)' direction='out'/></method>
            <method name='GetGroupProperties'><arg type='ai' direction='in'/><arg type='as' direction='in'/>
              <arg type='a(ia{sv})' direction='out'/></method>
            <method name='Event'><arg type='i' direction='in'/><arg type='s' direction='in'/>
              <arg type='v' direction='in'/><arg type='u' direction='in'/></method>
            <method name='AboutToShow'><arg type='i' direction='in'/><arg type='b' direction='out'/></method>
            <signal name='LayoutUpdated'><arg type='u'/><arg type='i'/></signal>
            <signal name='ItemsPropertiesUpdated'><arg type='a(ia{sv})'/><arg type='a(ias)'/></signal>
          </interface>
        </node>
        """
}
#endif
