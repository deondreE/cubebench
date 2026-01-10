#version 330 core
out vec4 FragColor;

in vec3 FragPos;
in vec3 Normal;
in vec3 ourColor;

uniform vec4 objectColor;

void main()
{
    vec3 lightDir = normalize(vec3(0.5, 1.0, 0.3));
    vec3 normal = normalize(Normal);
    
    float ambient = 0.4;
    float diffuse = max(dot(normal, lightDir), 0.0) * 0.6;
    float lighting = ambient + diffuse;
    
    vec3 result = objectColor.rgb * lighting;
    FragColor = vec4(result, objectColor.a);
}