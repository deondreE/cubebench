#version 330 core

in vec3 FragPos;
in vec3 Normal;
in vec2 TexCoord;
in vec3 WorldNormal;

out vec4 FragColor;

uniform vec4 objectColor;
uniform bool useTexture;
uniform sampler2D textureSampler;
uniform bool isSelected;
uniform int  highlightFace;

void main() {
    vec3 lightDir = normalize(vec3(0.5, 1.0, 0.3));
    vec3 norm = normalize(Normal);

    float diff = max(dot(norm, lightDir), 0.0);

    float ambient = 0.5;
    float lighting = ambient + diff * 0.5;

    vec4 baseColor;
    if (useTexture) {
        baseColor = texture(textureSampler, TexCoord);

        if (baseColor.a < 0.1) {
            baseColor = objectColor;
        }
    } else {
        baseColor = objectColor;
    }

    vec3 litColor = baseColor.rgb * lighting;

     if (isSelected) {
        litColor = mix(litColor, vec3(1.0, 0.6, 0.2), 0.2);
     }

     if (highlightFace >= 0) {
        int faceIndex = -1;

        vec3 absNormal = abs(WorldNormal);
        if (absNormal.z > 0.9 && WorldNormal.z > 0.0) faceIndex = 0;
        else if (absNormal.z > 0.9 && WorldNormal.z < 0.0) faceIndex = 1;
        else if (absNormal.x > 0.9 && WorldNormal.x < 0.0) faceIndex = 2;
        else if (absNormal.x > 0.9 && WorldNormal.x < 0.0) faceIndex = 3;
        else if (absNormal.y > 0.9 && WorldNormal.y > 0.0) faceIndex = 4;
        else if (absNormal.y > 0.9 && WorldNormal.y < 0.0) faceIndex = 5;

        if (faceIndex == highlightFace) {
            litColor = mix(litColor, vec3(0.3, 0.7, 1.0), 0.3);
        }
    }

    float edgeFactor = max(abs(dot(normalize(FragPos - vec3(0.0)), norm)), 0.0);
    litColor *= 0.85 + 0.15 * edgeFactor;

    FragColor = vec4(litColor, baseColor.a);
}
