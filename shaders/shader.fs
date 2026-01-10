#version 330 core

in vec3 FragPos;
in vec3 Normal;
in vec2 TexCoord;

out vec4 FragColor;

uniform vec4 objectColor;
uniform bool useTexture;
uniform sampler2D textureSampler;

void main() {
    // Simple lighting
    vec3 lightDir = normalize(vec3(1.0, 1.0, 1.0));
    float diff = max(dot(normalize(Normal), lightDir), 0.0);
    float ambient = 0.3;
    float lighting = ambient + diff * 0.7;
    
    vec4 baseColor;
    
    if (useTexture) {
        // Use texture with nearest neighbor filtering (pixel art)
        baseColor = texture(textureSampler, TexCoord);
    } else {
        baseColor = objectColor;
    }
    
    FragColor = vec4(baseColor.rgb * lighting, baseColor.a);
}