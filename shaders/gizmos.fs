#version 330 core
out vec4 FragColor;
uniform vec3 gizmoColor;
uniform bool isActive;

void main() {
    vec3 color = isActive ? vec3(1.0, 1.0, 1.0) : gizmoColor;
    FragColor = vec4(color, 1.0);
}
