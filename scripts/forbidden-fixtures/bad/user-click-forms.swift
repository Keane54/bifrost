func click() -> UserClick { .init() }
let clicks: [UserClick] = [.init()]
let viaSelf = UserClick.self.init()
func approve(_ click: UserClick) {}
func send(
    pr: PRKey,
    by: UserClick
) {}
