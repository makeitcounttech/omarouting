import QtQuick

// OmaRouting mark: one path in, splitting to two exits, the routing idea in a glyph.
// Stroke-only so it inherits the bar colour; dims via opacity like the old glyph.
Item {
    id: mark
    property color color: "white"
    property color accent: color          // optional live dot colour (connected)
    property bool live: false
    implicitWidth: 22
    implicitHeight: 22
    Canvas {
        id: canvas
        anchors.fill: parent
        renderStrategy: Canvas.Cooperative
        onPaint: {
            var ctx = getContext("2d")
            var w = width, h = height, s = Math.min(w, h)
            ctx.reset()
            ctx.clearRect(0, 0, w, h)
            ctx.lineWidth = Math.max(1.5, s * 0.095)
            ctx.lineCap = "round"
            ctx.lineJoin = "round"
            ctx.strokeStyle = mark.color
            var ox = (w - s) / 2, oy = (h - s) / 2
            function X(v) { return ox + v * s }
            function Y(v) { return oy + v * s }
            // trunk from the source node, forking into two curved routes
            ctx.beginPath()
            ctx.moveTo(X(0.22), Y(0.80))
            ctx.lineTo(X(0.22), Y(0.56))
            ctx.bezierCurveTo(X(0.22), Y(0.36), X(0.44), Y(0.30), X(0.62), Y(0.30))
            ctx.moveTo(X(0.22), Y(0.60))
            ctx.bezierCurveTo(X(0.22), Y(0.70), X(0.42), Y(0.74), X(0.62), Y(0.74))
            ctx.stroke()
            // arrow heads on both exits
            ctx.beginPath()
            ctx.moveTo(X(0.56), Y(0.20)); ctx.lineTo(X(0.70), Y(0.30)); ctx.lineTo(X(0.56), Y(0.40))
            ctx.moveTo(X(0.56), Y(0.64)); ctx.lineTo(X(0.70), Y(0.74)); ctx.lineTo(X(0.56), Y(0.84))
            ctx.stroke()
            // source node
            ctx.beginPath()
            ctx.arc(X(0.22), Y(0.80), s * 0.075, 0, Math.PI * 2)
            ctx.fillStyle = mark.color
            ctx.fill()
            // live dot (connected) at the upper exit
            if (mark.live) {
                ctx.beginPath()
                ctx.arc(X(0.86), Y(0.30), s * 0.085, 0, Math.PI * 2)
                ctx.fillStyle = mark.accent
                ctx.fill()
            }
        }
        Connections {
            target: mark
            function onColorChanged() { canvas.requestPaint() }
            function onAccentChanged() { canvas.requestPaint() }
            function onLiveChanged() { canvas.requestPaint() }
        }
        onWidthChanged: requestPaint()
        onHeightChanged: requestPaint()
    }
}
