/// All methods run on the UI thread. Delivery hide must not restore focus (§6.3).
public protocol PanelWindow {
    func show()
    func hideForDelivery()
    func hide()
}
